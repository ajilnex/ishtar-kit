import Foundation
import GRDB

/// Regroupement mécanique des éditions : le même livre en plusieurs fichiers
/// (PDF et EPUB d'une même édition) ne doit porter qu'une fiche et une clé.
///
/// Règle prudente : même premier auteur, même année, et le même titre — comparé
/// une fois accents, ponctuation, espaces et casse retirés — ou un titre qui
/// prolonge l'autre (« L ethique protestante », tronqué par un nom de fichier,
/// et « L'Éthique protestante et l'esprit du capitalisme »), sauf si le
/// prolongement est un tome ou un volume. Des traductions restent distinctes.
/// Le même livre à deux années différentes n'est pas une seule édition, mais
/// une seule **œuvre** à deux éditions : voir `workProposals`.
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

    /// Deux titres (squelettes) désignent-ils le même livre ? Égaux, ou l'un
    /// prolonge l'autre d'au moins dix lettres communes, sans que le
    /// prolongement soit un numéro de tome ou de volume.
    static func sameBook(_ a: String, _ b: String) -> Bool {
        if a == b { return !a.isEmpty }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 10, long.hasPrefix(short) else { return false }
        let rest = long.dropFirst(short.count)
        // « … vol 1 », « … tome 2 », « … t3 », « … 2 » : un autre tome, pas le même livre.
        if rest.first?.isNumber == true { return false }
        for marker in ["volume", "vol", "tome", "band", "book", "partie", "part", "livre"] where rest.hasPrefix(marker) {
            return false
        }
        if rest.hasPrefix("t"), rest.dropFirst().first?.isNumber == true { return false }
        return true
    }

    /// Titres qui ne disent rien du livre : jamais de regroupement sur eux.
    static let emptyTitles: Set<String> = ["unknown", "untitled", "sanstitre", "document", "texte", "livre", "book"]

    /// Le numéro de tome ou de volume que porte un titre (« Tome II », « Vol 1 »,
    /// « t. 3 »), en minuscules ; nil s'il n'en porte pas.
    static func volume(_ title: String) -> String? {
        let pattern = /(?i)\b(?:tome|vol\.?|volume|band|bd\.|book|part|partie|livre|t\.)\s*([0-9]+|[ivxlc]+)\b/
        return title.firstMatch(of: pattern).map { String($0.1).lowercased() }
    }

    /// Le numéro de tome en nombre (« II » → 2, « 3 » → 3), nil sans numéro.
    public static func volumeNumber(_ text: String, markers: [String]? = nil) -> Int? {
        let v: String?
        if let markers {
            let words = markers.joined(separator: "|")
            let regex = try? NSRegularExpression(pattern: "(?i)\\b(?:\(words))\\.?\\s*([0-9]+|[ivxlc]+)\\b")
            let range = NSRange(text.startIndex..., in: text)
            v = regex?.firstMatch(in: text, range: range).flatMap { Range($0.range(at: 1), in: text) }.map { String(text[$0]).lowercased() }
        } else {
            v = volume(text)
        }
        guard let v else { return nil }
        if let n = Int(v) { return n }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100]
        var total = 0, previous = 0
        for c in v.reversed() {
            guard let value = values[c] else { return nil }
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        return total
    }

    /// Même livre, titres complets en main : `sameBook` sur les squelettes, et
    /// des numéros de tome qui concordent (Tome I n'est pas Tome II).
    static func sameBook(title a: String, _ b: String) -> Bool {
        guard volume(a) == volume(b) else { return false }
        return sameBook(skeleton(a), skeleton(b))
    }

    /// Répartit des lignes en paquets de même livre. Chaque paquet ne réunit
    /// que des titres deux à deux `sameBook` ; un titre court qui convient à
    /// deux paquets (« Wilfrid Sellars », à côté de « Wilfrid Sellars: Fusing
    /// the Images » et de « Wilfrid Sellars on Truth ») n'est rattaché à aucun.
    static func clusters(_ rows: [Row]) -> [[Row]] {
        var clusters: [[Row]] = []
        for row in rows.sorted(by: { skeleton($0["title"]).count > skeleton($1["title"]).count }) {
            let title: String = row["title"]
            let fitting = clusters.indices.filter { i in clusters[i].allSatisfy { sameBook(title: $0["title"], title) } }
            if fitting.count == 1 {
                clusters[fitting[0]].append(row)
            } else {
                clusters.append([row])
            }
        }
        return clusters
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
                guard author != nil || year != nil, !skeleton(title).isEmpty,
                      !emptyTitles.contains(skeleton(title)) else { continue }
                // Le nom de famille seul : « Achebe » et « Chinua Achebe » sont le même auteur.
                let family = author.flatMap { CiteKeyGenerator.family($0) }?.lowercased() ?? ""
                let signature = "\(family)|\(CiteKeyGenerator.year(year) ?? "")"
                groups[signature, default: []].append(row)
            }
            return groups.values.flatMap(clusters).filter { $0.count > 1 }.map { members in
                // On garde d'abord une fiche corrigée à la main, puis le titre le
                // plus complet (le nom de fichier tronque), puis la clé nue.
                let sorted = members.sorted { a, b in
                    let ha = (a["confidence"] as String) == "high" ? 0 : 1, hb = (b["confidence"] as String) == "high" ? 0 : 1
                    let ta = -skeleton(a["title"]).count, tb = -skeleton(b["title"]).count
                    let ka: String = a["key"] ?? "~", kb: String = b["key"] ?? "~"
                    return (ha, ta, ka.contains("-") ? 1 : 0, ka) < (hb, tb, kb.contains("-") ? 1 : 0, kb)
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
            // La clé provisoire de l'édition gardée perd son « -b » s'il n'a plus lieu d'être.
            for g in groups {
                if let kept = try Edition.fetchOne(conn, key: g.keptEditionId) {
                    try EditionKey.refreshProvisional(forWork: kept.workId, conn)
                }
            }
            return absorbed
        }
    }

    /// Rattache des éditions à une autre : leurs fichiers la rejoignent (le
    /// même livre, prouvé par ailleurs). Rend le nombre d'éditions absorbées.
    @discardableResult
    public static func absorb(_ editions: [UUID], into kept: UUID, in db: CatalogDatabase) async throws -> Int {
        guard let edition = try await db.pool.read({ try Edition.fetchOne($0, key: kept) }) else { return 0 }
        let group = EditionGroup(keptEditionId: kept, absorbedEditionIds: editions, title: edition.title ?? "",
                                 author: nil, year: edition.year, keptKey: nil)
        return try await apply([group], to: db)
    }

    // MARK: Une œuvre, plusieurs éditions

    /// Le même livre (même auteur, même titre) en plusieurs fiches d'œuvre :
    /// deux éditions d'une seule œuvre (« Logic of the Future », 2019 et 2021),
    /// ou deux formats ingérés séparément.
    /// Chaque groupe : l'œuvre gardée d'abord (la plus ancienne), puis les
    /// œuvres dont les éditions la rejoignent.
    public static func workProposals(in db: CatalogDatabase) async throws -> [(kept: UUID, absorbed: [UUID], title: String, years: [String])] {
        try await db.pool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT w.id AS workId, w.title AS title, w.confidence AS confidence,
                       COALESCE(w.date, (SELECT MIN(e.year) FROM edition e WHERE e.workId = w.id)) AS year,
                       (SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                         WHERE wc.workId = w.id AND wc.role = 'author' ORDER BY wc.position LIMIT 1) AS author,
                       (SELECT group_concat(content, ' ') FROM (SELECT p.content FROM document_page p
                          JOIN document d ON d.id = p.documentId JOIN edition e ON e.id = d.editionId
                          WHERE e.workId = w.id AND d.isMissing = 0 AND p.pageNumber BETWEEN 1 AND 10
                          ORDER BY p.pageNumber LIMIT 10)) AS opening
                FROM work w
                WHERE EXISTS (SELECT 1 FROM edition e JOIN document d ON d.editionId = e.id
                              WHERE e.workId = w.id AND d.isMissing = 0)
                """)
            var byAuthor: [String: [Row]] = [:]
            for row in rows {
                let title: String = row["title"]
                guard let author: String = row["author"], let family = CiteKeyGenerator.family(author)?.lowercased(),
                      !emptyTitles.contains(skeleton(title)), !skeleton(title).isEmpty else { continue }
                byAuthor[family, default: []].append(row)
            }
            return byAuthor.values.flatMap(clusters).compactMap { members in
                // Deux œuvres du même auteur et du même titre sont une seule
                // œuvre, que leurs années diffèrent (éditions successives) ou
                // non (formats ingérés séparément : Aristophane en EPUB et MOBI).
                guard members.count > 1 else { return nil }
                // Le texte témoigne : chaque membre qui a un texte doit nommer
                // l'auteur dans ses premières pages (« The Legacy of Kant » de
                // Gironi n'est pas l'article de Stovall rangé sous son nom).
                for m in members {
                    guard let opening: String = m["opening"], opening.count >= 300,
                          let author: String = m["author"], let family = CiteKeyGenerator.family(author)?.lowercased()
                    else { continue }
                    if !skeleton(opening).contains(family) { return nil }
                }
                let sorted = members.sorted { a, b in
                    let ha = (a["confidence"] as String) == "high" ? 0 : 1, hb = (b["confidence"] as String) == "high" ? 0 : 1
                    return (ha, (a["year"] as String?) ?? "9999") < (hb, (b["year"] as String?) ?? "9999")
                }
                return (sorted[0]["workId"], sorted.dropFirst().map { $0["workId"] }, sorted[0]["title"],
                        sorted.compactMap { $0["year"] as String? })
            }.sorted { $0.title < $1.title }
        }
    }

    /// Les éditions des œuvres absorbées rejoignent l'œuvre gardée, qui prend
    /// pour année la plus ancienne. Rend le nombre d'œuvres absorbées.
    @discardableResult
    public static func applyWorks(_ groups: [(kept: UUID, absorbed: [UUID], title: String, years: [String])],
                                  to db: CatalogDatabase) async throws -> Int {
        try await db.pool.write { conn in
            var n = 0
            for g in groups {
                guard var kept = try Work.fetchOne(conn, key: g.kept) else { continue }
                for id in g.absorbed where id != g.kept {
                    guard let work = try Work.fetchOne(conn, key: id), work.confidence != .high else { continue }
                    try conn.execute(sql: "UPDATE edition SET workId = ? WHERE workId = ?", arguments: [kept.id, id])
                    try conn.execute(sql: """
                        INSERT OR IGNORE INTO collection_item (collectionId, workId)
                        SELECT collectionId, ? FROM collection_item WHERE workId = ?
                        """, arguments: [kept.id, id])
                    try conn.execute(sql: """
                        UPDATE OR IGNORE authority_link SET entityId = ? WHERE entityType = 'work' AND entityId = ?
                        """, arguments: [kept.id, id])
                    _ = try Work.deleteOne(conn, key: id)
                    n += 1
                }
                if kept.date == nil, let first = g.years.compactMap({ Int($0) }).min() {
                    kept.date = String(first)
                    try kept.update(conn)
                }
                try EditionKey.refreshProvisional(forWork: kept.id, conn)
            }
            try conn.execute(sql: """
                DELETE FROM creator WHERE id NOT IN (SELECT creatorId FROM work_creator)
                    AND id NOT IN (SELECT creatorId FROM edition_creator)
                """)
            return n
        }
    }
}
