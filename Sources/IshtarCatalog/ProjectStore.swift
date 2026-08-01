import Foundation
import GRDB

public struct ProjectStore: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    @discardableResult
    public func add(_ project: Project) async throws -> Project {
        try await db.pool.write { conn in
            try project.insert(conn)
        }
        return project
    }

    public func rename(id: UUID, newName: String) async throws {
        try await db.pool.write { conn in
            guard var project = try Project.fetchOne(conn, key: id) else { return }
            project.name = newName
            project.dateModified = Date()
            try project.update(conn)
        }
    }

    public func remove(id: UUID) async throws {
        try await db.pool.write { conn in
            // Remettre à nul le projectId des annotations pour qu'elles retombent dans la couche globale
            try conn.execute(sql: "UPDATE annotation SET projectId = NULL WHERE projectId = ?", arguments: [id])
            
            // Remettre à nul le projectId des encres
            try conn.execute(sql: "UPDATE link SET projectId = NULL WHERE projectId = ?", arguments: [id])
            
            // Les documents (project_item) sont supprimés par ON DELETE CASCADE
            try Project.deleteOne(conn, key: id)
        }
    }

    public func projects() async throws -> [Project] {
        try await db.pool.read { conn in
            try Project.order(Column("name")).fetchAll(conn)
        }
    }

    public func addDocument(_ documentId: UUID, toProjectId projectId: UUID) async throws {
        try await db.pool.write { conn in
            // ON CONFLICT DO NOTHING n'est pas utilisé, l'index UNIQUE gère l'unicité
            // S'il existe déjà, insert() va throw, ce qui est attendu.
            let item = ProjectItem(projectId: projectId, documentId: documentId)
            try item.insert(conn)
        }
    }

    public func removeDocument(_ documentId: UUID, fromProjectId projectId: UUID) async throws {
        try await db.pool.write { conn in
            try ProjectItem
                .filter(Column("projectId") == projectId && Column("documentId") == documentId)
                .deleteAll(conn)
        }
    }
}
