import Foundation
import GRDB

/// Regroupement mécanique des éditions : le même livre en plusieurs fichiers
/// (PDF et EPUB d'une même édition) ne doit porter qu'une fiche et une clé.
///
/// Règle prudente : même premier auteur, même titre, même année — comparés
/// une fois accents, ponctuation, espaces et casse retirés. Des tomes, des
/// traductions ou des éditions d'années différentes restent distincts.
/// Contrairement à la fusion humaine (`CatalogStore.merge`), la confiance
/// n'est pas relevée : c'est une proposition mécanique, que « Détacher »
/// défait.
public struct EditionGroup: Sendable, Equatable {
    /// L'édition conservée (celle qui porte la clé sans suffixe, sinon la plus ancienne clé).
    public let keptEditionId: UUID
    public let absorbedEditionIds: [UUID]
    public let title: String
    public let author: String?
    public let year: String?
    public let keptKey: String?
}

public enum EditionGrouping {
    static func skeleton(_ value: String?) -> String {
        CiteKeyGenerator.words(value ?? "").joined().lowercased()
    }

    public static func proposals(in db: CatalogDatabase) async throws -> [EditionGroup] {
        try await db.pool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT e.id AS editionId, e.year AS year, w.title AS title, w.confidence AS confidence,
                       (SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                         WHERE wc.workId = w.id AND wc.role = 'author' ORDER BY wc.position LIMIT 1) AS author,
                       k.key AS key
                FROM edition e JOIN work w ON w.id = e.workId
                LEFT JOIN edition_key k ON k.editionId = e.id
                WHERE EXISTS (SELECT 1 FROM document d WHERE d.editionId = e.id AND d.isMissing = 0)
                """)
            var groups: [String: [Row]] = [:]
            for row in rows {
                let title: String = row["title"]
                let author: String? = row["author"]
                let year: String? = row["year"]
                // Sans auteur ni année, trop peu d'indices pour affirmer « même livre ».
                guard author != nil || year != nil, !skeleton(title).isEmpty else { continue }
                // Le nom de famille seul : « Achebe » et « Chinua Achebe » sont le même auteur.
                let family = author.flatMap { CiteKeyGenerator.family($0) }?.lowercased() ?? ""
                let signature = "\(family)|\(skeleton(title))|\(CiteKeyGenerator.year(year) ?? "")"
                groups[signature, default: []].append(row)
            }
            return groups.values.filter { $0.count > 1 }.map { members in
                // On garde d'abord une fiche corrigée à la main, puis la clé nue
                // (sans « -2003 » ni « -b ») : c'est elle qu'on citerait.
                let sorted = members.sorted { a, b in
                    let ha = (a["confidence"] as String) == "high" ? 0 : 1, hb = (b["confidence"] as String) == "high" ? 0 : 1
                    let ka: String = a["key"] ?? "~", kb: String = b["key"] ?? "~"
                    return (ha, ka.contains("-") ? 1 : 0, ka) < (hb, kb.contains("-") ? 1 : 0, kb)
                }
                let kept = sorted[0]
                return EditionGroup(keptEditionId: kept["editionId"],
                                    absorbedEditionIds: sorted.dropFirst().map { $0["editionId"] },
                                    title: kept["title"], author: kept["author"], year: kept["year"],
                                    keptKey: kept["key"])
            }.sorted { $0.title < $1.title }
        }
    }

    /// Applique les regroupements ; rend le nombre d'éditions absorbées.
    @discardableResult
    public static func apply(_ groups: [EditionGroup], to db: CatalogDatabase) async throws -> Int {
        try await db.pool.write { conn in
            var absorbed = 0
            for g in groups {
                guard let kept = try Edition.fetchOne(conn, key: g.keptEditionId) else { continue }
                for id in g.absorbedEditionIds {
                    guard let edition = try Edition.fetchOne(conn, key: id), edition.id != kept.id else { continue }
                    // Les fichiers rejoignent l'édition conservée ; les collections de
                    // l'œuvre absorbée passent à l'œuvre conservée.
                    try conn.execute(sql: "UPDATE document SET editionId = ? WHERE editionId = ?",
                                     arguments: [kept.id, edition.id])
                    try conn.execute(sql: """
                        INSERT OR IGNORE INTO collection_item (collectionId, workId)
                        SELECT collectionId, ? FROM collection_item WHERE workId = ?
                        """, arguments: [kept.workId, edition.workId])
                    _ = try Edition.deleteOne(conn, key: edition.id)
                    absorbed += 1
                }
            }
            try conn.execute(sql: "DELETE FROM work WHERE id NOT IN (SELECT DISTINCT workId FROM edition)")
            try conn.execute(sql: """
                DELETE FROM creator WHERE id NOT IN (SELECT creatorId FROM work_creator)
                    AND id NOT IN (SELECT creatorId FROM edition_creator)
                """)
            return absorbed
        }
    }
}
