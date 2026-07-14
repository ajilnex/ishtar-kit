import Foundation
import IshtarCatalog
import PDFKit
import ZIPFoundation

/// Une page de texte extraite, avant insertion en base.
public struct ExtractedPage: Sendable, Equatable {
    public let number: Int
    public let content: String
}

/// Résultat d'une extraction : les pages indexables et le verdict OCR.
public struct ExtractedText: Sendable, Equatable {
    public var pages: [ExtractedPage]
    /// Vrai si le document est un scan sans couche texte : rien à indexer,
    /// l'OCR (postérieur, opt-in) sera nécessaire.
    public var needsOCR: Bool

    public init(pages: [ExtractedPage], needsOCR: Bool) {
        self.pages = pages
        self.needsOCR = needsOCR
    }
}

/// Extraction du texte d'un document, par format, locale et sans réseau
/// (invariant n° 1). Seuls PDF, EPUB, TXT et MD sont dans le périmètre ; les
/// autres formats (mobi, azw3, djvu, docx, rtf) sont ignorés proprement (nil).
public enum TextExtractor {
    /// Seuil moyen de caractères par page en-dessous duquel un PDF est jugé scanné.
    static let scannedPDFThreshold = 50
    /// Un item de spine EPUB dépassant cette taille est découpé en pages.
    static let epubSplitThreshold = 8000
    /// Taille cible d'une page découpée (EPUB volumineux, TXT, MD).
    static let pageTargetLength = 4000

    public static func extract(fileURL: URL, format: DocumentFormat) -> ExtractedText? {
        switch format {
        case .pdf: extractPDF(fileURL)
        case .epub: extractEPUB(fileURL)
        case .txt, .md: extractPlainText(fileURL)
        case .mobi, .azw3, .djvu, .docx, .rtf: nil // hors périmètre WP-03
        }
    }

    // MARK: - PDF

    static func extractPDF(_ url: URL) -> ExtractedText? {
        guard let document = PDFDocument(url: url) else { return nil }
        let count = document.pageCount
        guard count > 0 else { return ExtractedText(pages: [], needsOCR: false) }

        var pages: [ExtractedPage] = []
        var totalCharacters = 0
        for index in 0 ..< count {
            let text = document.page(at: index)?.string ?? ""
            totalCharacters += text.count
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                // Numéro de page réel (1-based).
                pages.append(ExtractedPage(number: index + 1, content: clean))
            }
        }

        // Moins de ~50 caractères par page en moyenne : c'est un scan. On n'indexe
        // rien et on signale le besoin d'OCR.
        if totalCharacters / count < scannedPDFThreshold {
            return ExtractedText(pages: [], needsOCR: true)
        }
        return ExtractedText(pages: pages, needsOCR: false)
    }

    // MARK: - EPUB

    static func extractEPUB(_ url: URL) -> ExtractedText? {
        guard let archive = try? Archive(url: url, accessMode: .read),
              let containerXML = entryData(archive, "META-INF/container.xml"),
              let container = try? XMLDocument(data: containerXML),
              let opfPath = (try? container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path"))?
                  .first?.stringValue,
              let opfXML = entryData(archive, opfPath),
              let opf = try? XMLDocument(data: opfXML)
        else { return nil }

        // Les href du manifest sont relatifs au dossier de l'OPF.
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        // manifest : id → href.
        var hrefById: [String: String] = [:]
        for node in (try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [] {
            guard let element = node as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue
            else { continue }
            hrefById[id] = href
        }

        // spine : l'ordre de lecture. Un item = une « page » (découpée si volumineuse).
        var pages: [ExtractedPage] = []
        var counter = 0
        for node in (try? opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? [] {
            guard let element = node as? XMLElement,
                  let idref = element.attribute(forName: "idref")?.stringValue,
                  let href = hrefById[idref]
            else { continue }

            // On écarte un éventuel fragment (#ancre) et on décode le pourcent-encodage.
            let rawPath = opfDir.isEmpty ? href : opfDir + "/" + href
            let noFragment = rawPath.split(separator: "#", maxSplits: 1).first.map(String.init) ?? rawPath
            let path = noFragment.removingPercentEncoding ?? noFragment

            guard let data = entryData(archive, path) else { continue }
            let text = xhtmlText(data)
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }

            let itemPages = clean.count > epubSplitThreshold
                ? paginate(clean, target: pageTargetLength)
                : [clean]
            for page in itemPages {
                counter += 1
                pages.append(ExtractedPage(number: counter, content: page))
            }
        }

        guard !pages.isEmpty else { return nil }
        return ExtractedText(pages: pages, needsOCR: false)
    }

    // MARK: - TXT / MD

    static func extractPlainText(_ url: URL) -> ExtractedText? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // UTF-8 d'abord, repli latin-1 (les vieux fichiers de bibliothèque).
        guard let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        let chunks = paginate(raw, target: pageTargetLength)
        let pages = chunks.enumerated().map { ExtractedPage(number: $0.offset + 1, content: $0.element) }
        return ExtractedText(pages: pages, needsOCR: false)
    }

    // MARK: - Découpage en pages

    /// Découpe un texte en pages d'environ `target` caractères, sur des frontières
    /// de paragraphe (lignes vides). Un paragraphe plus long que la cible est
    /// coupé durement.
    static func paginate(_ text: String, target: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var pages: [String] = []
        var current = ""
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let piece = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty { continue }

            if piece.count > target {
                if !current.isEmpty { pages.append(current); current = "" }
                pages.append(contentsOf: hardSplit(piece, size: target))
            } else if current.isEmpty {
                current = piece
            } else if current.count + 2 + piece.count > target {
                pages.append(current)
                current = piece
            } else {
                current += "\n\n" + piece
            }
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// Coupe une chaîne trop longue en tranches de `size` caractères.
    static func hardSplit(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start ..< end]))
            start = end
        }
        return chunks
    }

    // MARK: - Outils XHTML

    /// Texte d'un item XHTML. XMLDocument d'abord ; en cas d'échec de parsing
    /// (entités non déclarées, balisage cassé), repli par suppression des balises.
    static func xhtmlText(_ data: Data) -> String {
        if let document = try? XMLDocument(data: data),
           let body = (try? document.nodes(forXPath: "//*[local-name()='body']"))?.first,
           let value = body.stringValue
        {
            return normalizeWhitespace(value)
        }
        if let document = try? XMLDocument(data: data), let value = document.rootElement()?.stringValue {
            return normalizeWhitespace(value)
        }
        let markup = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return normalizeWhitespace(stripTags(markup))
    }

    static func stripTags(_ html: String) -> String {
        // Les scripts et styles ne portent pas de texte lisible : on les retire d'abord.
        var text = html.replacingOccurrences(
            of: #"<(script|style)[^>]*>[\s\S]*?</\1>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (code, glyph) in entities { text = text.replacingOccurrences(of: code, with: glyph) }
        // Entités numériques résiduelles : on les remplace par une espace.
        text = text.replacingOccurrences(of: #"&#\d+;"#, with: " ", options: .regularExpression)
        return text
    }

    static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func entryData(_ archive: Archive, _ path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }
}
