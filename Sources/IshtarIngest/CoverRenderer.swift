import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Couverture d'un document, rendue hors de l'application : QuickLook pour
/// tous les formats qu'il sait lire (la vraie couverture d'un EPUB), puis la
/// première page d'un PDF. Même taille que les vignettes de l'application
/// (120 × 170 pt @2x), si bien que les deux caches sont interchangeables.
///
/// Dette : `ThumbnailService` (ishtar-app) garde sa propre chaîne ; il devra
/// déléguer ici pour qu'il n'y ait qu'un pipeline (invariant n° 3).
public enum CoverRenderer {
    public static let pointSize = CGSize(width: 120, height: 170)
    public static let scale: CGFloat = 2

    /// PNG de la couverture, ou nil si rien de présentable n'a pu être rendu.
    /// `strictness` (0…1) applique l'examen de la page 1 aux images tirées
    /// d'une page ; nil n'examine rien.
    public static func png(for fileURL: URL, strictness: Double? = nil) async -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let isPDF = fileURL.pathExtension.lowercased() == "pdf"

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
           passes(rep.cgImage, strictness: isPDF ? strictness : nil) {
            return encode(rep.cgImage)
        }
        if isPDF, let image = firstPDFPage(fileURL), passes(image, strictness: strictness) {
            return encode(image)
        }
        return nil
    }

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
}
