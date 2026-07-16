import CSQLiteVec
import Foundation
import GRDB

/// Le magasin de vecteurs, dans un fichier SQLite SÉPARÉ du catalogue
/// (`…-embeddings.sqlite`). Choix délibéré : le schéma du catalogue reste un
/// format d'échange pur (sans extension C requise pour le lire), et l'index
/// vectoriel est jetable — le supprimer et réindexer est toujours sûr.
public final class EmbeddingStore: Sendable {
    public let pool: DatabasePool

    /// Le chemin conventionnel de l'index à côté d'un catalogue.
    public static func url(forCatalog catalogURL: URL) -> URL {
        catalogURL.deletingPathExtension().appendingPathExtension("embeddings.sqlite")
    }

    public init(at url: URL) throws {
        var configuration = Configuration()
        // Enregistre le module vec0 sur chaque connexion (liaison statique).
        configuration.prepareDatabase { db in
            sqlite3_vec_init(db.sqliteConnection, nil, nil)
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS page_map (
                    vec_rowid INTEGER PRIMARY KEY,
                    document_id TEXT NOT NULL,
                    page_number INTEGER NOT NULL,
                    UNIQUE(document_id, page_number)
                )
                """)
        }
    }

    /// Prépare la table vectorielle pour un modèle donné. Si le modèle ou la
    /// dimension changent, l'index existant est PURGÉ (réindexation nécessaire) —
    /// jamais de vecteurs hétérogènes mélangés.
    public func prepare(modelID: String, dimension: Int) throws {
        try pool.write { db in
            let storedModel = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'model'")
            let storedDim = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'dimension'")

            if storedModel != modelID || storedDim != String(dimension) {
                try db.execute(sql: "DROP TABLE IF EXISTS page_embedding")
                try db.execute(sql: "DELETE FROM page_map")
                try db.execute(sql: """
                    INSERT INTO meta(key, value) VALUES('model', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, arguments: [modelID])
                try db.execute(sql: """
                    INSERT INTO meta(key, value) VALUES('dimension', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, arguments: [String(dimension)])
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS page_embedding
                USING vec0(embedding float[\(dimension)])
                """)
        }
    }

    /// Les pages déjà indexées, pour ne jamais refaire le travail (idempotence).
    public func indexedPages() throws -> Set<PageKey> {
        try pool.read { db in
            var result = Set<PageKey>()
            let rows = try Row.fetchAll(
                db, sql: "SELECT document_id, page_number FROM page_map")
            for row in rows {
                if let id = UUID(uuidString: row["document_id"]) {
                    result.insert(PageKey(documentId: id, pageNumber: row["page_number"]))
                }
            }
            return result
        }
    }

    public struct PageKey: Hashable, Sendable {
        public let documentId: UUID
        public let pageNumber: Int
        public init(documentId: UUID, pageNumber: Int) {
            self.documentId = documentId
            self.pageNumber = pageNumber
        }
    }

    /// Insère un lot de vecteurs (une transaction). Les pages déjà présentes sont
    /// remplacées.
    public func insert(_ batch: [(key: PageKey, vector: [Float])]) throws {
        guard !batch.isEmpty else { return }
        try pool.write { db in
            for (key, vector) in batch {
                // Retire l'éventuel vecteur précédent de cette page.
                if let existing = try Int64.fetchOne(db, sql: """
                    SELECT vec_rowid FROM page_map
                    WHERE document_id = ? AND page_number = ?
                    """, arguments: [key.documentId.uuidString, key.pageNumber])
                {
                    try db.execute(sql: "DELETE FROM page_embedding WHERE rowid = ?",
                                   arguments: [existing])
                    try db.execute(sql: "DELETE FROM page_map WHERE vec_rowid = ?",
                                   arguments: [existing])
                }
                let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
                try db.execute(sql: "INSERT INTO page_embedding(embedding) VALUES (?)",
                               arguments: [blob])
                let rowid = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO page_map(vec_rowid, document_id, page_number)
                    VALUES (?, ?, ?)
                    """, arguments: [rowid, key.documentId.uuidString, key.pageNumber])
            }
        }
    }

    /// Les k pages les plus proches du vecteur requête (distance L2 de vec0).
    public func nearest(to query: [Float], limit: Int) throws -> [(key: PageKey, distance: Double)] {
        try pool.read { db in
            let blob = query.withUnsafeBufferPointer { Data(buffer: $0) }
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.document_id, m.page_number, e.distance
                FROM page_embedding e
                JOIN page_map m ON m.vec_rowid = e.rowid
                WHERE e.embedding MATCH ? AND k = ?
                ORDER BY e.distance
                """, arguments: [blob, limit])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["document_id"]) else { return nil }
                return (PageKey(documentId: id, pageNumber: row["page_number"]),
                        row["distance"])
            }
        }
    }

    public func count() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_map") ?? 0
        }
    }
}
