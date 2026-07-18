import Foundation
import GRDB

/// Les surlignements : création, note, couleur, suppression, lecture. Rien
/// d'autre — la résolution d'ancrage vit à côté (`AnnotationAnchor`),
/// l'interface au-dessus.
public struct AnnotationStore: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    @discardableResult
    public func add(_ annotation: Annotation) async throws -> Annotation {
        try await db.pool.write { conn in
            try annotation.insert(conn)
        }
        return annotation
    }

    public func updateNote(id: UUID, note: String?) async throws {
        try await db.pool.write { conn in
            guard var annotation = try Annotation.fetchOne(conn, key: id) else { return }
            annotation.note = note
            annotation.dateModified = Date()
            try annotation.update(conn)
        }
    }

    public func setColor(id: UUID, color: String?) async throws {
        try await db.pool.write { conn in
            guard var annotation = try Annotation.fetchOne(conn, key: id) else { return }
            annotation.color = color
            annotation.dateModified = Date()
            try annotation.update(conn)
        }
    }

    public func remove(id: UUID) async throws {
        _ = try await db.pool.write { conn in
            try Annotation.deleteOne(conn, key: id)
        }
    }

    /// Les surlignements d'un document, dans l'ordre de lecture (page puis
    /// date de création — les EPUB, sans page, suivent la date).
    public func annotations(documentId: UUID) async throws -> [Annotation] {
        try await db.pool.read { conn in
            try Annotation
                .filter(Column("documentId") == documentId)
                .fetchAll(conn)
                .sorted {
                    switch ($0.pageNumber, $1.pageNumber) {
                    case let (a?, b?) where a != b: return a < b
                    case (nil, _?): return false
                    case (_?, nil): return true
                    default: return $0.dateCreated < $1.dateCreated
                    }
                }
        }
    }

    public func count() async throws -> Int {
        try await db.pool.read { try Annotation.fetchCount($0) }
    }
}
