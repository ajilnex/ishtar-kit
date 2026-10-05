import Foundation
import IshtarCatalog
import ZIPFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

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
        case .mobi, .azw3, .azw: readMOBI(fileURL)
        case .docx: readDOCX(fileURL)
        case .fb2: readFictionBook(fileURL, zipped: false)
        case .fbz: readFictionBook(fileURL, zipped: true)
        default: nil
        }
    }

    // MARK: - Famille MOBI

    /// Les enregistrements EXTH portent titre, auteur, éditeur, ISBN et date —
    /// c'est le meilleur étage 2 de tous les formats, quand le fichier n'est
    /// pas verrouillé.
    static func readMOBI(_ url: URL) -> MetadataGuess? {
        guard let document = try? MOBIDocument(fileURL: url) else { return nil }
        let meta = document.metadata

        let title = sanitizedTitle(meta.title)
        let author = sanitizedAuthor(meta.author)
        let isbn13 = meta.isbn.flatMap { MetadataPatterns.isbn13(in: $0) }

        guard title != nil || author != nil || isbn13 != nil else { return nil }
        return MetadataGuess(
            title: title ?? "",
            author: author,
            year: meta.date.flatMap { MetadataPatterns.year(in: $0) },
            publisher: meta.publisher?.isEmpty == true ? nil : meta.publisher,
            language: meta.language.map { String($0.prefix(2)).lowercased() },
            isbn13: isbn13,
            confidence: .structured
        )
    }

    // MARK: - DOCX

    /// `docProps/core.xml` : du Dublin Core, comme l'OPF d'un EPUB. Souvent
    /// sale (l'auteur est le nom de session Windows) — le filtre d'hygiène
    /// commun s'en charge.
    static func readDOCX(_ url: URL) -> MetadataGuess? {
        guard let core = OfficeDocument.docxMetadata(url) else { return nil }
        let title = sanitizedTitle(core.title)
        let author = sanitizedAuthor(core.author)
        guard title != nil || author != nil else { return nil }
        return MetadataGuess(title: title ?? "", author: author, confidence: .structured)
    }

    // MARK: - FictionBook

    static func readFictionBook(_ url: URL, zipped: Bool) -> MetadataGuess? {
        guard let info = OfficeDocument.fictionBookMetadata(url, zipped: zipped) else { return nil }
        let title = sanitizedTitle(info.title)
        let author = sanitizedAuthor(info.author)
        guard title != nil || author != nil else { return nil }
        return MetadataGuess(title: title ?? "", author: author, confidence: .structured)
    }

    // MARK: - PDF

    static func readPDF(_ url: URL) -> MetadataGuess? {
        guard let document = PDFSource.open(url) else { return nil }

        let title = sanitizedTitle(document.title)
        let author = sanitizedAuthor(document.author)

        // ISBN/DOI dans les premières pages (page de titre, page de copyright).
        var isbn13: String?
        var doi: String?
        for pageIndex in 0..<min(document.pageCount, 8) {
            guard let text = document.text(pageIndex) else { continue }
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
        return guess(fromOPF: opf)
    }

    /// Le Dublin Core d'un OPF : celui d'un EPUB, ou la fiche d'une
    /// bibliothèque Calibre.
    static func guess(fromOPF opf: XMLDocument) -> MetadataGuess? {
        func dc(_ element: String) -> String? {
            let nodes = (try? opf.nodes(forXPath: "//*[local-name()='\(element)']")) ?? []
            return nodes.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let title = sanitizedTitle(dc("title"))
        let author = sanitizedAuthor(dc("creator"))
        let year = dc("date").flatMap { MetadataPatterns.year(in: $0) }
        let publisher = dc("publisher")
        let language = dc("language").map(languageCode)

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

    /// ISO 639-1 (« fr ») d'un code de langue OPF, qui vient souvent en trois
    /// lettres (Calibre : « fra », « spa ») ou avec sa région (« fr-FR »).
    static func languageCode(_ raw: String) -> String {
        let code = raw.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        let threeLetters = ["fra": "fr", "fre": "fr", "eng": "en", "deu": "de", "ger": "de", "ita": "it", "spa": "es",
                            "por": "pt", "rus": "ru", "lat": "la", "ell": "el", "gre": "el", "nld": "nl", "dut": "nl",
                            "pol": "pl", "ces": "cs", "cze": "cs", "jpn": "ja", "zho": "zh", "chi": "zh", "ara": "ar",
                            "heb": "he", "cat": "ca", "swe": "sv", "dan": "da", "nor": "no", "fin": "fi", "hun": "hu",
                            "tur": "tr", "ukr": "uk", "ron": "ro", "rum": "ro"]
        return threeLetters[code] ?? String(code.prefix(2))
    }

    // MARK: - Fiche Calibre

    /// La fiche qu'une bibliothèque Calibre pose à côté du livre
    /// (`metadata.opf`, le Dublin Core d'un OPF) : relue par son propriétaire,
    /// elle vaut mieux que le nom de fichier (« Titre - Auteur », la convention
    /// de Calibre, qui se lit à l'envers). Un dossier Calibre ne contient qu'un
    /// livre, en un ou plusieurs formats : ailleurs, la fiche n'est pas lue.
    public static func readCalibreSidecar(for fileURL: URL) -> MetadataGuess? {
        let folder = fileURL.deletingLastPathComponent()
        let sidecar = folder.appendingPathComponent("metadata.opf")
        guard let data = try? Data(contentsOf: sidecar),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let books = Set(names.filter { !$0.hasPrefix(".") && DocumentFormat(fileExtension: ($0 as NSString).pathExtension) != nil }
            .map { ($0 as NSString).deletingPathExtension })
        guard books.count == 1, let opf = try? XMLDocument(data: data) else { return nil }
        return guess(fromOPF: opf)
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
