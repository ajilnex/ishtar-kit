import Foundation
import GRDB
import IshtarCatalog

/// Un passage trouvé par la recherche plein texte : la page, son extrait en
/// contexte, et l'œuvre (titre + auteurs) à laquelle il appartient.
public struct PassageHit: Identifiable, Sendable, Hashable {
    public var id: String { "\(documentId.uuidString)#\(pageNumber)" }
    public let documentId: UUID
    public let pageNumber: Int
    /// Extrait avec le terme cerné par « … » (fonction FTS5 `snippet`).
    public let snippet: String
    public let title: String
    public let authors: [String]

    public init(documentId: UUID, pageNumber: Int, snippet: String, title: String, authors: [String]) {
        self.documentId = documentId
        self.pageNumber = pageNumber
        self.snippet = snippet
        self.title = title
        self.authors = authors
    }
}

/// Recherche plein texte FTS5, classée par pertinence (bm25).
///
/// Foyer unique de la recherche plein texte (invariant n° 3) : l'app n'a jamais
/// deux chemins. La recherche de métadonnées reste dans `CatalogSearch`.
public struct FulltextSearch: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    public func search(_ query: String, limit: Int = 40) async throws -> [PassageHit] {
        guard let match = Self.makeMatchQuery(query) else { return [] }

        return try await db.pool.read { conn in
            // Passages classés par bm25 (le plus pertinent d'abord). La jointure
            // remonte titre et œuvre ; snippet cerne le terme en contexte.
            let rows = try Row.fetchAll(conn, sql: """
                SELECT
                    dp.documentId AS documentId,
                    dp.pageNumber AS pageNumber,
                    snippet(document_page_fts, 0, '«', '»', '…', 12) AS snippet,
                    work.id AS workId,
                    work.title AS title
                FROM document_page_fts
                JOIN document_page dp ON dp.rowid = document_page_fts.rowid
                JOIN document ON document.id = dp.documentId
                JOIN edition ON edition.id = document.editionId
                JOIN work ON work.id = edition.workId
                WHERE document_page_fts MATCH ?
                ORDER BY bm25(document_page_fts)
                LIMIT ?
                """, arguments: [match, limit])

            // Auteurs des œuvres concernées, en une seule requête (pas de N+1).
            let workIds = Array(Set(rows.map { $0["workId"] as UUID }))
            var authorsByWork: [UUID: [String]] = [:]
            if !workIds.isEmpty {
                let placeholders = databaseQuestionMarks(count: workIds.count)
                let authorRows = try Row.fetchAll(conn, sql: """
                    SELECT work_creator.workId AS workId, creator.name AS name
                    FROM work_creator
                    JOIN creator ON creator.id = work_creator.creatorId
                    WHERE work_creator.workId IN (\(placeholders))
                    ORDER BY work_creator.position
                    """, arguments: StatementArguments(workIds))
                for row in authorRows {
                    let workId: UUID = row["workId"]
                    authorsByWork[workId, default: []].append(row["name"])
                }
            }

            return rows.map { row in
                let workId: UUID = row["workId"]
                return PassageHit(
                    documentId: row["documentId"],
                    pageNumber: row["pageNumber"],
                    snippet: row["snippet"],
                    title: row["title"],
                    authors: authorsByWork[workId] ?? []
                )
            }
        }
    }

    /// Neutralise la syntaxe FTS5 d'une saisie brute (guillemets, astérisques,
    /// deux-points, parenthèses, opérateurs) : chaque terme devient un bareword
    /// nu, jamais un opérateur. Le dernier terme reçoit une étoile de préfixe
    /// pour la recherche incrémentale. Renvoie nil si la saisie n'a aucun terme.
    static func makeMatchQuery(_ raw: String) -> String? {
        // On coupe sur tout ce qui n'est pas alphanumérique (unicode), ce qui
        // élimine d'un coup les caractères spéciaux FTS5. Le passage en minuscules
        // désarme aussi les opérateurs AND/OR/NOT/NEAR (sensibles à la casse).
        var terms = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        terms[terms.count - 1] += "*"
        return terms.joined(separator: " ")
    }

    private func databaseQuestionMarks(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
