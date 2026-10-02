import Foundation
import IshtarCatalog

/// Export de travail personnel. La citation de la source et le commentaire
/// de son lecteur restent explicitement séparés ; aucun fichier source ne change.
public enum AnnotationMarkdownExport {
    public enum Language: Sendable { case french, english }

    public static func markdown(title: String, citation: String, editionKey: String?,
                                annotations: [Annotation], language: Language = .french) -> String {
        let english = language == .english
        var lines = ["# \(english ? "Reading notes" : "Notes de lecture") — \(escape(title))", "", escape(citation), ""]
        if let editionKey { lines += ["\(english ? "Edition key" : "Clé d’édition") : `\(escape(editionKey))`", ""] }
        for item in annotations.sorted(by: {
            if $0.pageNumber != $1.pageNumber { return ($0.pageNumber ?? Int.max) < ($1.pageNumber ?? Int.max) }
            return $0.dateCreated == $1.dateCreated ? $0.id.uuidString < $1.id.uuidString : $0.dateCreated < $1.dateCreated
        }) {
            let heading = item.pageNumber.map { "\(english ? "Page" : "Page") \($0)" }
                ?? (english ? "Passage" : "Passage")
            lines += ["## \(heading)", ""]
            lines += item.quote.components(separatedBy: .newlines).map { "> \(escape($0))" }
            lines.append("")
            if let note = item.note, !note.isEmpty {
                lines += ["**\(english ? "Personal note" : "Note personnelle") :**", "", escape(note), ""]
            }
            let reference: LibraryLink.Reference = editionKey.map(LibraryLink.Reference.edition) ?? .document(item.documentId)
            let link = LibraryLink(reference: reference, page: item.pageNumber, quote: item.quote).url
            lines += ["[\(english ? "Read in Ishtar" : "Lire dans Ishtar")](<\(link.absoluteString)>)", "", "---", ""]
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\", with: "\\\\")
        for symbol in ["`", "*", "_", "[", "]", "<", ">", "#", "|"] {
            result = result.replacingOccurrences(of: symbol, with: "\\" + symbol)
        }
        return result
    }
}
