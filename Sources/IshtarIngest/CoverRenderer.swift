#if canImport(QuickLookThumbnailing)
import CoreGraphics
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
#endif
import Foundation
import IshtarCatalog
#if !canImport(QuickLookThumbnailing)
import ZIPFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#endif

/// Couverture d'un document, rendue hors de l'application : QuickLook pour
/// tous les formats qu'il sait lire (la vraie couverture d'un EPUB), puis la
/// première page d'un PDF. Même taille que les vignettes de l'application
/// (120 × 170 pt @2x), si bien que les deux caches sont interchangeables.
///
/// Seul pipeline de couvertures (invariant n° 3) : `ThumbnailService`
/// (ishtar-app) et la publication passent tous deux par ici.
public enum CoverRenderer {
    public static let pointSize = CGSize(width: 120, height: 170)
    public static let scale: CGFloat = 2

    /// PNG de la couverture, ou nil si rien de présentable n'a pu être rendu.
    /// `strictness` (0…1) applique l'examen de la page 1 aux images tirées
    /// d'une page ; nil n'examine rien.
    ///
    /// **L'examen ne vise QUE les images tirées d'une page** (PDF, texte,
    /// DjVu…). Les livres que foliate sait ouvrir (EPUB, MOBI, AZW3…) portent
    /// une vraie couverture : l'examiner reviendrait à refuser une couverture
    /// d'éditeur légitimement sobre.
    public static func png(for fileURL: URL, strictness: Double? = nil) async -> Data? {
        #if canImport(QuickLookThumbnailing)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let format = DocumentFormat(fileName: fileURL.lastPathComponent)
        let isPDF = format == .pdf
        let examined = format?.readingEngine == .foliate ? nil : strictness

        // Kindle (MOBI, AZW, AZW3) : QuickLook ne sait pas les lire, mais le
        // fichier porte sa couverture — on la prend telle quelle.
        if ["mobi", "azw", "azw3", "prc"].contains(fileURL.pathExtension.lowercased()),
           let raw = MOBIDocument.coverImage(fileURL: fileURL),
           let image = scaled(raw) {
            return encode(image)
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL, size: pointSize, scale: scale, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
           passes(rep.cgImage, strictness: examined) {
            return encode(rep.cgImage)
        }
        if isPDF, let image = firstPDFPage(fileURL), passes(image, strictness: examined) {
            return encode(image)
        }
        return nil
        #else
        return machinePNG(for: fileURL, strictness: strictness)
        #endif
    }

    #if canImport(QuickLookThumbnailing)

    static func passes(_ image: CGImage, strictness: Double?) -> Bool {
        guard let strictness, let stats = CoverInspector.statistics(of: image) else { return true }
        return CoverInspector.judge(stats, strictness: strictness) == nil
    }

    /// Première page d'un PDF en Core Graphics pur (pas d'AppKit dans le moteur).
    static func firstPDFPage(_ url: URL) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let target = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        let ratio = min(target.width / box.width, target.height / box.height)
        let width = Int(box.width * ratio), height = Int(box.height * ratio)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: ratio, y: ratio)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Une image quelconque ramenée à la taille des vignettes, proportions gardées.
    static func scaled(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(pointSize.height * scale),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    #else
    // MARK: - Sous Linux (l'outil du serveur, WP-34)

    /// Même ordre que sur macOS : la couverture que porte un livre Kindle ou un
    /// EPUB (non examinée, comme sur macOS : une couverture d'éditeur peut être
    /// sobre) ; puis la première page d'un PDF, examinée si `strictness` est
    /// donné. Rendus par poppler et ImageMagick ; les autres formats n'ont pas
    /// de couverture ici (Rayons en dessine une).
    static func machinePNG(for fileURL: URL, strictness: Double?) -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let format = DocumentFormat(fileName: fileURL.lastPathComponent)
        let examined = format?.readingEngine == .foliate ? nil : strictness
        let ext = fileURL.pathExtension.lowercased()

        if ["mobi", "azw", "azw3", "prc"].contains(ext), let raw = MOBIDocument.coverImage(fileURL: fileURL) {
            return thumbnail(of: raw)
        }
        if ext == "epub", let raw = epubCover(fileURL) {
            return thumbnail(of: raw)
        }
        guard format == .pdf else { return nil }
        return MachineTools.withTemporaryDirectory { dir -> Data? in
            let prefix = dir.appendingPathComponent("page").path
            if let examined {
                // L'examen sur la page réduite à 64 × 64, comme sur macOS.
                guard MachineTools.run("pdftoppm", ["-f", "1", "-l", "1", "-singlefile", "-scale-to-x", "64",
                                                    "-scale-to-y", "64", fileURL.path, prefix + "-examen"]) != nil,
                      let ppm = try? Data(contentsOf: URL(fileURLWithPath: prefix + "-examen.ppm")),
                      let pixels = Self.rgbPixels(ppm: ppm)
                else { return nil }
                if let stats = CoverInspector.statistics(pixels: pixels, bytesPerPixel: 3),
                   CoverInspector.judge(stats, strictness: examined) != nil { return nil }
            }
            let side = Int(pointSize.height * scale)
            guard MachineTools.run("pdftoppm", ["-f", "1", "-l", "1", "-singlefile", "-png", "-scale-to", String(side),
                                                fileURL.path, prefix]) != nil
            else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: prefix + ".png"))
        }
    }

    /// Une image quelconque (JPEG, PNG, GIF) ramenée à la taille des vignettes, en PNG.
    static func thumbnail(of raw: Data) -> Data? {
        MachineTools.withTemporaryDirectory { dir -> Data? in
            let source = dir.appendingPathComponent("couverture")
            guard (try? raw.write(to: source)) != nil else { return nil }
            let box = "\(Int(pointSize.width * scale))x\(Int(pointSize.height * scale))"
            guard let png = MachineTools.run("convert", [source.path + "[0]", "-auto-orient", "-thumbnail", box, "png:-"]),
                  !png.isEmpty else { return nil }
            return png
        }
    }

    /// L'image de couverture d'un EPUB, telle que l'OPF la désigne (EPUB 3 :
    /// `properties="cover-image"` ; EPUB 2 : `<meta name="cover">`).
    static func epubCover(_ url: URL) -> Data? {
        guard let archive = try? Archive(url: url, accessMode: .read),
              let container = TextExtractor.entryData(archive, "META-INF/container.xml"),
              let containerXML = try? XMLDocument(data: container),
              let opfPath = (try? containerXML.nodes(forXPath: "//*[local-name()='rootfile']/@full-path"))?.first?.stringValue,
              let opfData = TextExtractor.entryData(archive, opfPath),
              let opf = try? XMLDocument(data: opfData)
        else { return nil }
        let items = ((try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [])
            .compactMap { $0 as? XMLElement }
        let coverId = ((try? opf.nodes(forXPath: "//*[local-name()='meta'][@name='cover']/@content")) ?? []).first?.stringValue
        let chosen = items.first { $0.plainAttribute("properties")?.split(separator: " ").contains("cover-image") == true }
            ?? items.first { coverId != nil && $0.plainAttribute("id") == coverId }
            ?? items.first {
                ($0.plainAttribute("media-type")?.hasPrefix("image/") == true)
                    && ($0.plainAttribute("href")?.lowercased().contains("cover") == true)
            }
        guard let href = chosen?.plainAttribute("href") else { return nil }
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        let raw = opfDir.isEmpty ? href : opfDir + "/" + href
        return TextExtractor.entryData(archive, raw.removingPercentEncoding ?? raw)
    }

    /// Les pixels d'une image PPM binaire (P6, 8 bits), en RVB. Pur.
    static func rgbPixels(ppm: Data) -> [UInt8]? {
        let bytes = [UInt8](ppm)
        var index = 0
        var tokens: [Int] = []
        // Trois nombres après « P6 » : largeur, hauteur, valeur maximale ; les commentaires (#) sautés.
        guard bytes.count > 2, bytes[0] == UInt8(ascii: "P"), bytes[1] == UInt8(ascii: "6") else { return nil }
        index = 2
        while tokens.count < 3, index < bytes.count {
            let c = bytes[index]
            if c == UInt8(ascii: "#") { while index < bytes.count, bytes[index] != 10 { index += 1 }; continue }
            if c >= 48, c <= 57 {
                var n = 0
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { n = n * 10 + Int(bytes[index] - 48); index += 1 }
                tokens.append(n)
                continue
            }
            index += 1
        }
        guard tokens.count == 3, tokens[2] == 255, index < bytes.count else { return nil }
        index += 1 // l'unique blanc qui suit la valeur maximale
        let expected = tokens[0] * tokens[1] * 3
        guard bytes.count - index >= expected else { return nil }
        return Array(bytes[index ..< index + expected])
    }
    #endif
}
