import Foundation
import IshtarCatalog
import PDFKit
import ZIPFoundation

/// Deuxième étage de l'entonnoir : les métadonnées embarquées dans le document.
/// Local, déterministe, sans réseau — comme tout ce qui précède les catalogues publics.
///
/// - PDF : dictionnaire Info (titre, auteur) + balayage ISBN/DOI des premières pages.
/// - EPUB : fichier OPF (Dublin Core : titre, créateur, date, éditeur, langue, ISBN).
///
/// Les métadonnées embarquées sont souvent sales (« Microsoft Word - final2.doc »,
/// auteur « user ») : on filtre agressivement, mieux vaut ne rien proposer que
/// proposer du bruit.
public enum EmbeddedMetadata {
    public static func read(fileURL: URL, format: DocumentFormat) -> MetadataGuess? {
        switch format {
        case .pdf: readPDF(fileURL)
        case .epub: readEPUB(fileURL)
        default: nil
        }
    }

    // MARK: - PDF

    static func readPDF(_ url: URL) -> MetadataGuess? {
        guard let document = PDFDocument(url: url) else { return nil }

        let attributes = document.documentAttributes ?? [:]
        let title = sanitizedTitle(attributes[PDFDocumentAttribute.titleAttribute] as? String)
        let author = sanitizedAuthor(attributes[PDFDocumentAttribute.authorAttribute] as? String)

        // ISBN/DOI dans les premières pages (page de titre, page de copyright).
        var isbn13: String?
        var doi: String?
        for pageIndex in 0..<min(document.pageCount, 8) {
            guard let text = document.page(at: pageIndex)?.string else { continue }
            if isbn13 == nil { isbn13 = MetadataPatterns.isbn13(in: text) }
            if doi == nil { doi = MetadataPatterns.doi(in: text) }
            if isbn13 != nil, doi != nil { break }
        }

        guard title != nil || author != nil || isbn13 != nil || doi != nil else { return nil }
        return MetadataGuess(
            title: title ?? "",
            author: author,
            isbn13: isbn13,
            doi: doi,
            confidence: .structured
        )
    }

    // MARK: - EPUB

    static func readEPUB(_ url: URL) -> MetadataGuess? {
        guard let archive = try? Archive(url: url, accessMode: .read),
              let containerXML = extract(from: archive, path: "META-INF/container.xml"),
              let container = try? XMLDocument(data: containerXML),
              let opfPath = (try? container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path"))?
                  .first?.stringValue,
              let opfXML = extract(from: archive, path: opfPath),
              let opf = try? XMLDocument(data: opfXML)
        else { return nil }

        func dc(_ element: String) -> String? {
            let nodes = (try? opf.nodes(forXPath: "//*[local-name()='\(element)']")) ?? []
            return nodes.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let title = sanitizedTitle(dc("title"))
        let author = sanitizedAuthor(dc("creator"))
        let year = dc("date").flatMap { MetadataPatterns.year(in: $0) }
        let publisher = dc("publisher")
        let language = dc("language").map { String($0.prefix(2)).lowercased() }

        // L'ISBN peut se trouver dans n'importe quel dc:identifier.
        let identifiers = (try? opf.nodes(forXPath: "//*[local-name()='identifier']")) ?? []
        let isbn13 = identifiers
            .compactMap { $0.stringValue }
            .compactMap { MetadataPatterns.isbn13(in: $0) }
            .first

        guard title != nil || author != nil || isbn13 != nil else { return nil }
        return MetadataGuess(
            title: title ?? "",
            author: author,
            year: year,
            publisher: publisher?.isEmpty == true ? nil : publisher,
            language: language,
            isbn13: isbn13,
            confidence: .structured
        )
    }

    private static func extract(from archive: Archive, path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }

    // MARK: - Hygiène des métadonnées embarquées

    /// Rejette les titres manifestement machinaux.
    static func sanitizedTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              title.count >= 4
        else { return nil }

        let junkMarkers = [
            "microsoft word", "untitled", "sans titre", "sans nom", ".doc", ".indd",
            ".qxd", ".pmd", ".tex", ".dvi", "print", "scan", "ocr-", "output",
        ]
        let lowered = title.lowercased()
        if junkMarkers.contains(where: { lowered.contains($0) }) { return nil }
        if title.filter(\.isLetter).count < 3 { return nil }

        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return title
    }

    /// Rejette les auteurs manifestement machinaux.
    static func sanitizedAuthor(_ raw: String?) -> String? {
        guard let author = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              author.count >= 3, author.count <= 120
        else { return nil }

        let junk = ["user", "admin", "unknown", "inconnu", "owner", "windows", "apple"]
        if junk.contains(author.lowercased()) { return nil }
        if author.filter(\.isLetter).count < 3 { return nil }
        return author
    }
}
