import Foundation
import GRDB

public struct LinkStore: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    @discardableResult
    public func add(_ link: Link) async throws -> Link {
        try await db.pool.write { conn in
            try link.insert(conn)
        }
        return link
    }

    public func remove(id: UUID) async throws {
        _ = try await db.pool.write { conn in
            try Link.deleteOne(conn, key: id)
        }
    }

    public func links(forAnnotationId annotationId: UUID) async throws -> [Link] {
        try await db.pool.read { conn in
            try Link.filter(Column("sourceAnnotationId") == annotationId || Column("targetAnnotationId") == annotationId).fetchAll(conn)
        }
    }

    public func links(forDocumentId documentId: UUID) async throws -> [Link] {
        try await db.pool.read { conn in
            try Link.fetchAll(conn, sql: """
                SELECT DISTINCT link.* 
                FROM link
                JOIN annotation a1 ON link.sourceAnnotationId = a1.id
                JOIN annotation a2 ON link.targetAnnotationId = a2.id
                WHERE a1.documentId = ? OR a2.documentId = ?
                """, arguments: [documentId, documentId])
        }
    }

    public func links(forProjectId projectId: UUID) async throws -> [Link] {
        try await db.pool.read { conn in
            try Link.filter(Column("projectId") == projectId).fetchAll(conn)
        }
    }
}
