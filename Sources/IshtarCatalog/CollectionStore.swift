import Foundation
import GRDB

/// Une collection relie des œuvres déjà présentes ; aucune copie de document.
public struct CollectionStore: Sendable {
    private let db: CatalogDatabase
    public init(db: CatalogDatabase) { self.db = db }

    /// Ajout idempotent. Toutes les clés sont résolues avant le premier changement.
    public func add(keys: [String], to name: String, apply: Bool) async throws -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DatabaseError(message: "Nom de collection vide.") }
        return try await db.pool.write { conn in
            var works = Set<UUID>()
            for key in keys {
                guard let row = try Row.fetchOne(conn, sql: """
                    SELECT e.workId FROM edition_key k JOIN edition e ON e.id = k.editionId WHERE k.key = ?
                    """, arguments: [key]) else { throw DatabaseError(message: "Clé inconnue : \(key)") }
                works.insert(row["workId"])
            }
            let candidates = try BookCollection.filter(Column("name") == name && Column("parentId") == nil && Column("sourceFolderPath") == nil).fetchAll(conn)
            guard candidates.count <= 1 else { throw DatabaseError(message: "Plusieurs collections portent ce nom.") }
            let collection = candidates.first ?? BookCollection(name: name)
            guard apply else { return candidates.first?.id }
            try collection.insert(conn, onConflict: .ignore)
            for work in works { try CollectionItem(collectionId: collection.id, workId: work).insert(conn, onConflict: .ignore) }
            return collection.id
        }
    }
}
