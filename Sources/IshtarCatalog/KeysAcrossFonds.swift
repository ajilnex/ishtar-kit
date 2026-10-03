import Foundation
import GRDB

/// Une clé déjà publiée par un autre fonds de kenosème (WP-34) : ses fichiers
/// (empreintes) et son ISBN disent quelle édition elle désigne.
public struct OtherFondsKey: Sendable, Equatable {
    public let hashes: Set<String>
    public let isbn13: String?

    public init(hashes: Set<String>, isbn13: String? = nil) {
        self.hashes = hashes
        self.isbn13 = isbn13
    }
}

extension CatalogStore {
    /// Les clés d'un fonds confié face à celles des autres fonds publiés :
    /// une clé ne désigne qu'une édition dans tout kenosème. Une édition du
    /// fonds qui est la même qu'ailleurs (un même fichier, ou le même ISBN)
    /// prend la clé qu'elle y porte ; une autre édition, dont la clé est prise
    /// ailleurs, en reçoit une libre (`-b`, `-c`…). Les clés changées sont
    /// figées (`stable`) : les passes locales, qui ignorent les autres fonds,
    /// ne doivent pas les rendre. Une clé manuelle ne bouge jamais. Rend les
    /// changements, dans l'ordre des clés.
    @discardableResult
    public func separateKeys(from foreign: [String: OtherFondsKey]) async throws -> [(from: String, to: String)] {
        // Ordre fixe : la même édition reçoit toujours la même clé.
        let sortedForeign = foreign.sorted { $0.key < $1.key }
        var foreignKeys = Set<String>()
        var keyByHash: [String: String] = [:]
        var keyByISBN: [String: String] = [:]
        for (key, value) in sortedForeign {
            foreignKeys.insert(key.lowercased())
            for hash in value.hashes where keyByHash[hash] == nil { keyByHash[hash] = key }
            if let isbn = value.isbn13, !isbn.isEmpty, keyByISBN[isbn] == nil { keyByISBN[isbn] = key }
        }
        let (foreignSet, hashIndex, isbnIndex) = (foreignKeys, keyByHash, keyByISBN)
        return try await db.pool.write { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT k.editionId AS editionId, k.key AS key, k.origin AS origin, e.isbn13 AS isbn13,
                       (SELECT group_concat(d.contentHash) FROM document d
                         WHERE d.editionId = k.editionId AND d.contentHash IS NOT NULL) AS hashes
                FROM edition_key k JOIN edition e ON e.id = k.editionId
                ORDER BY k.key
                """)
            var local = Set(rows.map { ($0["key"] as String).lowercased() })
            var changes: [(from: String, to: String)] = []
            for row in rows {
                let key: String = row["key"]
                guard (row["origin"] as String) != EditionKey.Origin.manual.rawValue else { continue }
                let hashes = ((row["hashes"] as String?) ?? "").split(separator: ",").map(String.init)
                let isbn: String? = row["isbn13"]
                let same = hashes.compactMap { hashIndex[$0] }.sorted().first ?? isbn.flatMap { isbnIndex[$0] }
                if let same, same.lowercased() == key.lowercased() { continue }
                let target: String
                if let same, !local.contains(same.lowercased()) {
                    // La même édition ailleurs : sa clé, qu'aucune autre édition du fonds ne porte.
                    target = same
                } else if foreignSet.contains(key.lowercased()) {
                    target = CiteKeyGenerator.unique(base: key, editionYear: nil, taken: local.union(foreignSet))
                } else {
                    continue
                }
                try conn.execute(sql: "UPDATE edition_key SET key = ?, origin = ? WHERE editionId = ?",
                                 arguments: [target, EditionKey.Origin.stable.rawValue, row["editionId"] as UUID])
                local.remove(key.lowercased())
                local.insert(target.lowercased())
                changes.append((key, target))
            }
            return changes
        }
    }
}
