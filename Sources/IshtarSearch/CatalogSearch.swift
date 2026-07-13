import Foundation
import GRDB
import IshtarCatalog

/// Recherche dans le catalogue.
///
/// M0 : recherche de métadonnées (titre, auteur) en SQL simple.
/// M1 branchera FTS5 (plein texte) puis M3 la recherche sémantique (sqlite-vec) —
/// ce module est leur foyer, pour que l'app n'ait jamais deux chemins de recherche.
public struct CatalogSearch: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    public struct WorkHit: Identifiable, Sendable, Hashable {
        public var id: UUID { work.id }
        public let work: Work
        public let authors: [String]
    }

    public func works(matching query: String, limit: Int = 100) async throws -> [WorkHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await db.pool.read { dbConn in
            let works: [Work]
            if trimmed.isEmpty {
                works = try Work.order(Column("title")).limit(limit).fetchAll(dbConn)
            } else {
                let pattern = "%\(trimmed)%"
                works = try Work.fetchAll(dbConn, sql: """
                    SELECT DISTINCT work.*
                    FROM work
                    LEFT JOIN work_creator ON work_creator.workId = work.id
                    LEFT JOIN creator ON creator.id = work_creator.creatorId
                    WHERE work.title LIKE ?
                       OR work.subtitle LIKE ?
                       OR creator.name LIKE ?
                    ORDER BY work.title
                    LIMIT ?
                    """, arguments: [pattern, pattern, pattern, limit])
            }

            return try works.map { work in
                let authors = try String.fetchAll(dbConn, sql: """
                    SELECT creator.name
                    FROM creator
                    JOIN work_creator ON work_creator.creatorId = creator.id
                    WHERE work_creator.workId = ?
                    ORDER BY work_creator.position
                    """, arguments: [work.id])
                return WorkHit(work: work, authors: authors)
            }
        }
    }
}
