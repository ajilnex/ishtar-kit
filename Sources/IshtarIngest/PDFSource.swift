import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Un PDF tel que le moteur le lit : nombre de pages, texte de chaque page,
/// titre et auteur du dictionnaire Info. La seule porte vers le contenu d'un PDF
/// pour l'extraction du texte et l'étage 2 de l'entonnoir (invariant n° 3 :
/// un seul pipeline, deux lecteurs) — PDFKit sur macOS ; sous Linux (l'outil
/// `ishtar` du serveur, WP-34), poppler (`pdfinfo`, `pdftotext`).
struct PDFSource {
    let pageCount: Int
    let title: String?
    let author: String?
    /// Le texte de la page `index` (à partir de 0), nil si elle est illisible.
    let text: (Int) -> String?

    static func open(_ url: URL) -> PDFSource? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { return nil }
        let attributes = document.documentAttributes ?? [:]
        return PDFSource(
            pageCount: document.pageCount,
            title: attributes[PDFDocumentAttribute.titleAttribute] as? String,
            author: attributes[PDFDocumentAttribute.authorAttribute] as? String,
            text: { document.page(at: $0)?.string })
        #else
        guard let raw = MachineTools.run("pdfinfo", ["-enc", "UTF-8", url.path], timeout: 30),
              let info = String(data: raw, encoding: .utf8)
        else { return nil }
        let fields = Self.infoFields(info)
        let count = Int(fields["Pages"] ?? "") ?? 0
        let reader = PopplerText(url: url, pageCount: count)
        return PDFSource(pageCount: count, title: fields["Title"], author: fields["Author"],
                         text: { reader.page($0) })
        #endif
    }

    /// Les champs de `pdfinfo` (« Title:   Minima moralia »). Pur.
    static func infoFields(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty, fields[key] == nil { fields[key] = value }
        }
        return fields
    }

    /// Les pages d'une sortie de `pdftotext` : une page par saut de page (U+000C). Pur.
    static func pagesFromPdftotext(_ output: String) -> [String] {
        var pages = output.components(separatedBy: "\u{0C}")
        // `pdftotext` termine chaque page par un saut : le dernier morceau est vide.
        if pages.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { pages.removeLast() }
        return pages
    }
}

#if !canImport(PDFKit)
/// Le texte d'un PDF par poppler, lu à la demande : les premières pages seules
/// suffisent à l'étage 2 (ISBN, DOI) ; tout le livre pour l'extraction.
private final class PopplerText {
    let url: URL
    let pageCount: Int
    static let headLength = 8
    private var head: [String]?
    private var all: [String]?

    init(url: URL, pageCount: Int) {
        self.url = url
        self.pageCount = pageCount
    }

    func page(_ index: Int) -> String? {
        guard index >= 0, index < pageCount else { return nil }
        if all == nil, index < Self.headLength {
            if head == nil { head = read(last: min(Self.headLength, pageCount)) }
            return head.flatMap { index < $0.count ? $0[index] : nil }
        }
        if all == nil { all = read(last: nil) }
        return all.flatMap { index < $0.count ? $0[index] : nil }
    }

    private func read(last: Int?) -> [String] {
        var arguments = ["-enc", "UTF-8", "-q"]
        if let last { arguments += ["-f", "1", "-l", String(last)] }
        arguments += [url.path, "-"]
        guard let data = MachineTools.run("pdftotext", arguments, timeout: 600),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return [] }
        return PDFSource.pagesFromPdftotext(text)
    }
}
#endif
