import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
/// Sous Linux (outil du serveur, WP-34) : l'empreinte portable, même usage.
private typealias SHA256 = PortableSHA256
#endif
import GRDB
import IshtarCatalog

/// Un passage trouvé par la recherche sémantique (ou hybride).
public struct SemanticHit: Identifiable, Sendable, Hashable {
    public var id: String { "\(documentId)-\(pageNumber)" }
    public let documentId: UUID
    public let pageNumber: Int
    public let title: String
    public let authors: [String]
    /// Extrait : le snippet FTS si le passage vient (aussi) du lexical, sinon le
    /// début de la page.
    public let excerpt: String
    public let score: Double
}

/// L'indexeur sémantique : vectorise en tâche de fond les pages extraites qui ne
/// le sont pas encore (idempotent). Local, jamais bloquant, tolérant aux erreurs
/// unitaires — même contrat que l'extraction de texte.
public struct SemanticIndexer: Sendable {
    let db: CatalogDatabase
    let store: EmbeddingStore
    let embeddings: LocalEmbeddings
    let allowAssetDownload: Bool

    public init(db: CatalogDatabase, store: EmbeddingStore, embeddings: LocalEmbeddings,
                allowAssetDownload: Bool = true) {
        self.db = db
        self.store = store
        self.embeddings = embeddings
        self.allowAssetDownload = allowAssetDownload
    }

    /// Vectorise toutes les pages en attente. Retourne le nombre traité.
    public func indexAllPending(
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int {
        if allowAssetDownload { try await embeddings.ensureAssets() }
        else { try embeddings.loadInstalledAssets() }
        try store.prepare(modelID: embeddings.modelID, dimension: embeddings.dimension)

        let already = try store.indexedContentDigests()
        let pages: [(EmbeddingStore.PageKey, String)] = try await db.pool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT documentId, pageNumber, content FROM document_page ORDER BY documentId, pageNumber
                """)
            return rows.compactMap { row in
                // GRDB stocke les UUID en blob de 16 octets : on décode en UUID,
                // jamais en String (leçon d'épreuve du réel).
                guard let id: UUID = row["documentId"] else { return nil }
                let key = EmbeddingStore.PageKey(documentId: id, pageNumber: row["pageNumber"])
                return (key, row["content"])
            }
        }
        try Task.checkCancellation()
        let digests = Dictionary(uniqueKeysWithValues: pages.map { ($0.0, Self.digest($0.1)) })
        // Identité de page ET contenu : OCR et remplacement de fichier ne
        // peuvent plus laisser un ancien vecteur sous la même référence.
        try store.remove(Set(already.keys.filter { digests[$0] != already[$0] }))
        let pending = pages.filter { digests[$0.0] != already[$0.0] }

        let total = pending.count
        guard total > 0 else { return 0 }

        var done = 0
        var batch: [(key: EmbeddingStore.PageKey, vector: [Float])] = []
        for (key, content) in pending {
            try Task.checkCancellation()
            do {
                batch.append((key, try embeddings.embed(content)))
            } catch {
                // Une page illisible ne bloque jamais le lot.
                FileHandle.standardError.write(Data("Embedding raté p.\(key.pageNumber): \(error)\n".utf8))
            }
            done += 1
            if batch.count >= 64 {
                try Task.checkCancellation()
                try store.insert(batch, contentDigests: digests)
                batch.removeAll(keepingCapacity: true)
                progress?(done, total)
            }
        }
        try Task.checkCancellation()
        try store.insert(batch, contentDigests: digests)
        progress?(done, total)
        return done
    }

    static func digest(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// La recherche hybride : candidats lexicaux (FTS5) + voisins sémantiques (vec0),
/// fusionnés par Reciprocal Rank Fusion — la méthode simple et éprouvée, sans
/// pondération à régler.
public struct SemanticSearch: Sendable {
    let db: CatalogDatabase
    let store: EmbeddingStore
    let embeddings: LocalEmbeddings

    public init(db: CatalogDatabase, store: EmbeddingStore, embeddings: LocalEmbeddings) {
        self.db = db
        self.store = store
        self.embeddings = embeddings
    }

    public func search(_ query: String, limit: Int = 20) async throws -> [SemanticHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        // Voie lexicale (peut être vide si aucun terme ne correspond).
        let lexical = (try? await FulltextSearch(db: db).search(trimmed, limit: 40)) ?? []

        // Voie sémantique (peut être vide si l'index n'est pas construit).
        var semantic: [(key: EmbeddingStore.PageKey, distance: Double)] = []
        if (try? store.count()).map({ $0 > 0 }) == true {
            // L’index vectoriel est facultatif : son échec ne retire jamais
            // les passages que le plein texte sait trouver.
            if let vector = try? embeddings.embed(trimmed) {
                semantic = (try? store.nearest(to: vector, limit: 40)) ?? []
            }
        }

        // Fusion RRF : score(page) = Σ 1/(60 + rang) sur chaque liste.
        struct Key: Hashable { let doc: UUID; let page: Int }
        var scores: [Key: Double] = [:]
        var ftsSnippets: [Key: String] = [:]
        for (rank, hit) in lexical.enumerated() {
            let key = Key(doc: hit.documentId, page: hit.pageNumber)
            scores[key, default: 0] += 1.0 / (60.0 + Double(rank + 1))
            ftsSnippets[key] = hit.snippet
        }
        for (rank, item) in semantic.enumerated() {
            let key = Key(doc: item.key.documentId, page: item.key.pageNumber)
            scores[key, default: 0] += 1.0 / (60.0 + Double(rank + 1))
        }
        let ranked = Array(scores.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            if $0.key.doc != $1.key.doc { return $0.key.doc.uuidString < $1.key.doc.uuidString }
            return $0.key.page < $1.key.page
        }.prefix(limit))
        guard !ranked.isEmpty else { return [] }
        let snippets = ftsSnippets // copie immuable pour la fermeture Sendable

        // Habillage : titre, auteurs, extrait — depuis le catalogue.
        return try await db.pool.read { conn in
            var hits: [SemanticHit] = []
            for (key, score) in ranked {
                guard let row = try Row.fetchOne(conn, sql: """
                    SELECT w.title AS title, dp.content AS content
                    FROM document d
                    JOIN edition e ON e.id = d.editionId
                    JOIN work w ON w.id = e.workId
                    LEFT JOIN document_page dp
                        ON dp.documentId = d.id AND dp.pageNumber = ?
                    WHERE d.id = ?
                    """, arguments: [key.page, key.doc]) else { continue }
                let authors = try String.fetchAll(conn, sql: """
                    SELECT c.name FROM creator c
                    JOIN work_creator wc ON wc.creatorId = c.id
                    JOIN work w ON w.id = wc.workId
                    JOIN edition e ON e.workId = w.id
                    JOIN document d ON d.editionId = e.id
                    WHERE d.id = ? AND wc.role = 'author' ORDER BY wc.position
                    """, arguments: [key.doc])
                let content: String? = row["content"]
                let excerpt = snippets[.init(doc: key.doc, page: key.page)]
                    ?? content.map { String($0.prefix(220)) } ?? ""
                hits.append(SemanticHit(
                    documentId: key.doc, pageNumber: key.page,
                    title: row["title"], authors: authors,
                    excerpt: excerpt, score: score))
            }
            return hits
        }
    }
}
