import Foundation
import GRDB
import IshtarCatalog

/// Une ligne de la bibliothèque telle que l'app l'affiche :
/// le document, son édition, son œuvre et ses auteurs, réunis.
public struct LibraryRow: Identifiable, Sendable, Hashable {
    public var id: UUID { document.id }
    public let work: Work
    public let authors: [String]
    public let edition: Edition?
    public let document: Document

    public init(work: Work, authors: [String], edition: Edition?, document: Document) {
        self.work = work
        self.authors = authors
        self.edition = edition
        self.document = document
    }
}

public struct CatalogStats: Sendable, Equatable {
    public var total = 0
    public var recognized = 0
    public var needsReview = 0
    public var duplicates = 0

    public init() {}
}

/// Vue d'ensemble du catalogue pour l'interface : lignes, statistiques,
/// collections et appartenances. Lecture seule.
public struct LibraryOverview: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    public func rows() async throws -> [LibraryRow] {
        try await db.pool.read { conn in
            let documents = try Document.order(Column("originalFileName")).fetchAll(conn)
            let editions = try Edition.fetchAll(conn)
            let works = try Work.fetchAll(conn)

            let editionById = Dictionary(uniqueKeysWithValues: editions.map { ($0.id, $0) })
            let workById = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })

            // Auteurs par œuvre, en une seule requête.
            var authorsByWork: [UUID: [String]] = [:]
            let rows = try Row.fetchAll(conn, sql: """
                SELECT work_creator.workId AS workId, creator.name AS name
                FROM work_creator
                JOIN creator ON creator.id = work_creator.creatorId
                ORDER BY work_creator.position
                """)
            for row in rows {
                let workId: UUID = row["workId"]
                authorsByWork[workId, default: []].append(row["name"])
            }

            return documents.compactMap { document in
                guard let editionId = document.editionId,
                      let edition = editionById[editionId],
                      let work = workById[edition.workId]
                else { return nil }
                return LibraryRow(
                    work: work,
                    authors: authorsByWork[work.id] ?? [],
                    edition: edition,
                    document: document
                )
            }
            .sorted {
                ($0.authors.first ?? "\u{FFFF}", $0.work.title, $0.edition?.year ?? "")
                    < ($1.authors.first ?? "\u{FFFF}", $1.work.title, $1.edition?.year ?? "")
            }
        }
    }

    public func stats() async throws -> CatalogStats {
        try await db.pool.read { conn in
            var stats = CatalogStats()
            stats.total = try Document.fetchCount(conn)
            stats.recognized = try Document
                .filter(Column("curationStatus") == CurationStatus.recognized.rawValue)
                .fetchCount(conn)
            stats.needsReview = try Document
                .filter(Column("curationStatus") == CurationStatus.needsReview.rawValue)
                .fetchCount(conn)
            stats.duplicates = try Document
                .filter(Column("curationStatus") == CurationStatus.duplicateCandidate.rawValue)
                .fetchCount(conn)
            return stats
        }
    }

    public func collections() async throws -> [BookCollection] {
        try await db.pool.read { conn in
            try BookCollection.order(Column("name")).fetchAll(conn)
        }
    }

    /// Appartenances œuvre → collections, pour filtrer côté interface.
    public func membership() async throws -> [UUID: Set<UUID>] {
        try await db.pool.read { conn in
            var map: [UUID: Set<UUID>] = [:]
            for item in try CollectionItem.fetchAll(conn) {
                map[item.workId, default: []].insert(item.collectionId)
            }
            return map
        }
    }
}
