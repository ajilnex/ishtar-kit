import Foundation
import GRDB
import IshtarCatalog

/// Livre ou article : les deux rayons d'une bibliothèque de recherche
/// (décision d'Aubin, 25/09). Les chapitres tirés d'un livre, les
/// communications et les prépublications vont avec les articles.
public enum DocumentKind: String, Codable, Sendable {
    case livre, article

    static let articleMarks = [
        "jstor", "doi.org", "doi:", " doi ", "journal", "revue", "review", "proceedings", "vol.", "no.", "pp.",
        "abstract", "résumé", "preprint", "biorxiv", "arxiv", "researchgate", "persee", "persée", "cairn",
        "forthcoming", "to appear", "in press", "online first", "open access", "cite this", "citer ce document",
        "published by", "stable url", "keywords", "mots-clés", "chapter ", "chapitre "
    ]
    static let bookMarks = [
        "isbn", "table des matières", "contents", "du même auteur", "collection", "tous droits",
        "all rights reserved", "achevé d'imprimer", "dépôt légal", "printed in", "presses universitaires",
        "university press", "éditions", "editions", "library of congress", "british library"
    ]

    /// Le genre de chaque document présent du catalogue — le même calcul pour
    /// la publication (Rayons) et pour l'application (sections Livres /
    /// Articles) : format, nombre de pages, marques des premières pages.
    public static func kinds(in db: CatalogDatabase) async throws -> [UUID: DocumentKind] {
        try await db.pool.read { conn in try kinds(conn) }
    }

    static func kinds(_ conn: Database) throws -> [UUID: DocumentKind] {
        var kinds: [UUID: DocumentKind] = [:]
        for row in try Row.fetchAll(conn, sql: """
            SELECT d.id AS id, d.format AS format,
                   (SELECT count(*) FROM document_page p WHERE p.documentId = d.id) AS pages,
                   (SELECT group_concat(substr(content, 1, 2500), ' ') FROM (SELECT content FROM document_page p
                      WHERE p.documentId = d.id AND p.pageNumber BETWEEN 1 AND 4 ORDER BY p.pageNumber)) AS opening
            FROM document d WHERE d.isMissing = 0
            """) {
            guard let format = DocumentFormat(rawValue: row["format"]) else { continue }
            kinds[row["id"]] = classify(format: format, pages: row["pages"], opening: row["opening"] ?? "")
        }
        return kinds
    }

    /// Le genre d'un document (pur). `pages` : pages extraites ; `opening` :
    /// le texte des premières pages.
    public static func classify(format: DocumentFormat, pages: Int, opening: String) -> DocumentKind {
        switch format {
        case .epub, .mobi, .azw, .azw3, .fb2, .fbz, .kfx: return .livre
        case .cbz, .cbr, .djvu: return .livre
        default: break
        }
        guard pages > 0 else { return .livre }
        let text = opening.lowercased()
        let article = articleMarks.filter { text.contains($0) }.count
        let book = bookMarks.filter { text.contains($0) }.count
        if pages >= 120 { return .livre }
        if pages <= 45 { return book >= 3 && article == 0 ? .livre : .article }
        if pages <= 70 { return book > article + 1 ? .livre : .article }
        return article > book + 1 ? .article : .livre
    }
}
