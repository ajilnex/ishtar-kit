import Foundation
import GRDB
import IshtarCatalog

/// Une restauration proposée pour une œuvre.
public struct TypographyProposal: Sendable, Equatable {
    public let workId: UUID
    public let oldTitle: String
    public let newTitle: String?
    public let oldAuthor: String?
    public let newAuthor: String?
}

/// Parcourt le catalogue et propose, œuvre par œuvre, la graphie que le
/// fichier porte lui-même (étage 2 de l'entonnoir, local, sans réseau).
/// Les œuvres corrigées à la main (confiance haute) sont laissées de côté.
public enum TypographyPass {
    public static func proposals(in db: CatalogDatabase) async throws -> [TypographyProposal] {
        struct Candidate { let workId: UUID; let title: String; let author: String?; let path: String; let format: DocumentFormat }
        let candidates: [Candidate] = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT w.id AS workId, w.title AS title,
                       (SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                         WHERE wc.workId = w.id AND wc.role = 'author' ORDER BY wc.position LIMIT 1) AS author,
                       d.filePath AS path, d.format AS format
                FROM work w
                JOIN edition e ON e.workId = w.id
                JOIN document d ON d.editionId = e.id AND d.isMissing = 0
                WHERE w.confidence != 'high'
                GROUP BY w.id
                """).compactMap { row in
                guard let format = DocumentFormat(rawValue: row["format"]) else { return nil }
                return Candidate(workId: row["workId"], title: row["title"], author: row["author"],
                                 path: row["path"], format: format)
            }
        }

        var result: [TypographyProposal] = []
        for c in candidates {
            guard let embedded = EmbeddedMetadata.read(fileURL: URL(fileURLWithPath: c.path), format: c.format) else { continue }
            let title = TypographyRestorer.restoredTitle(current: c.title, embedded: embedded.title)
            let author = c.author.flatMap { TypographyRestorer.restoredAuthor(current: $0, embedded: embedded.author) }
            if title != nil || author != nil {
                result.append(TypographyProposal(workId: c.workId, oldTitle: c.title, newTitle: title,
                                                 oldAuthor: c.author, newAuthor: author))
            }
        }
        return result
    }

    /// Applique les propositions ; rend le nombre d'œuvres modifiées.
    @discardableResult
    public static func apply(_ proposals: [TypographyProposal], to db: CatalogDatabase) async throws -> Int {
        let store = CatalogStore(db: db)
        var changed = 0
        for p in proposals {
            let author = p.newAuthor.flatMap { new in p.oldAuthor.map { (from: $0, to: new) } }
            if try await store.applyTypography(workId: p.workId, title: p.newTitle, author: author) { changed += 1 }
        }
        return changed
    }
}
