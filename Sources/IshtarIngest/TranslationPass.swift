import Foundation
import GRDB
import IshtarCatalog

/// Des livres possédés qui sont la même œuvre selon Wikidata : un original et
/// ses traductions (ou plusieurs traductions), aujourd'hui fiches séparées.
public struct TranslationGroup: Sendable {
    public let qid: String
    public let label: String
    public let originalTitle: String?
    public let originalLanguage: String?
    public let year: String?
    /// L'œuvre gardée d'abord (l'original s'il est possédé), puis les autres.
    public let works: [(id: UUID, title: String, languages: [String])]
}

/// Relie originaux et traductions (IFLA LRM : une œuvre, plusieurs
/// expressions ; NORMES §1). Pour chaque auteur relié à Wikidata et présent
/// avec au moins deux livres, on lit ses œuvres et tous leurs titres
/// (libellés dans les langues d'Europe, titres des éditions et traductions) ;
/// un livre possédé est rattaché à une œuvre Wikidata quand un de ses titres
/// est le sien, et une seule. Deux livres rattachés à la même œuvre sont
/// réunis : les éditions gardent leur titre et leur langue, l'œuvre prend son
/// titre original et sa date.
public enum TranslationPass {
    struct OurWork { let id: UUID; let title: String; let languages: [String]; let confidence: String }

    /// L'œuvre Wikidata d'un de nos titres : une seule, ou nil (pur).
    static func match(_ title: String, in works: [WikidataWork]) -> WikidataWork? {
        let hits = works.filter { $0.titles.contains { AuthorityPass.sameTitle(title, $0) } }
        return hits.count == 1 ? hits[0] : nil
    }

    public static func proposals(in db: CatalogDatabase, wikidata: WikidataConnector = WikidataConnector(),
                                 links: inout [AuthorityLink]) async throws -> [TranslationGroup] {
        let rows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT a.identifier AS qid, w.id AS workId, w.title AS title, w.confidence AS confidence,
                       (SELECT group_concat(DISTINCT e.language) FROM edition e WHERE e.workId = w.id) AS languages
                FROM authority_link a
                JOIN work_creator wc ON wc.creatorId = a.entityId AND wc.role = 'author'
                JOIN work w ON w.id = wc.workId
                WHERE a.entityType = 'creator' AND a.scheme = 'wikidata' AND a.status = 'confirmed'
                  AND w.confidence != 'high'
                """)
        }
        var byAuthor: [String: [OurWork]] = [:]
        for row in rows {
            let langs = (row["languages"] as String?)?.split(separator: ",").map(String.init) ?? []
            byAuthor[row["qid"], default: []].append(OurWork(id: row["workId"], title: row["title"], languages: langs, confidence: row["confidence"]))
        }
        var groups: [TranslationGroup] = []
        for (qid, ours) in byAuthor.sorted(by: { $0.key < $1.key }) where ours.count >= 2 {
            guard let works = try? await wikidata.works(ofAuthor: qid), !works.isEmpty else { continue }
            var byWork: [String: [OurWork]] = [:]
            for our in ours {
                guard let w = match(our.title, in: works) else { continue }
                byWork[w.qid, default: []].append(our)
                links.append(AuthorityLink(entityType: .work, entityId: our.id, scheme: .wikidata, identifier: w.qid,
                                           label: w.label, status: .confirmed,
                                           evidence: "« \(our.title) » est un titre de cette œuvre dans Wikidata"))
            }
            for (wqid, members) in byWork where members.count >= 2 {
                guard let w = works.first(where: { $0.qid == wqid }) else { continue }
                // L'original d'abord, s'il est possédé ; sinon l'ordre des titres.
                let sorted = members.sorted { a, b in
                    let oa = w.language.map { a.languages.contains($0) } ?? false ? 0 : 1
                    let ob = w.language.map { b.languages.contains($0) } ?? false ? 0 : 1
                    return (oa, a.title) < (ob, b.title)
                }
                groups.append(TranslationGroup(qid: wqid, label: w.label, originalTitle: w.originalTitle,
                                               originalLanguage: w.language, year: w.year,
                                               works: sorted.map { ($0.id, $0.title, $0.languages) }))
            }
            try? await Task.sleep(nanoseconds: 300_000_000)   // politesse envers le service
        }
        return groups
    }

    public enum ReunionError: Error, CustomStringConvertible {
        case unknownKey(String)
        case tooFew
        public var description: String {
            switch self {
            case let .unknownKey(key): return "Clé inconnue : \(key)"
            case .tooFew: return "Il faut au moins deux clés, l'original d'abord."
            }
        }
    }

    /// Réunit à la main, sur pièce, des livres possédés qui sont la même œuvre
    /// (un original et ses traductions). La première clé désigne l'original :
    /// son œuvre est gardée, avec son titre et sa date ; chaque édition garde
    /// le titre sous lequel elle a paru. Contrairement à la passe Wikidata, une
    /// fiche vérifiée peut être réunie : c'est une décision humaine, dont la
    /// preuve rejoint les notes de l'œuvre. Les clés ne changent pas (une clé
    /// provisoire suit sa fiche). Rend le nombre d'œuvres absorbées.
    @discardableResult
    public static func reunir(keys: [String], preuve: String, date: String, in db: CatalogDatabase) async throws -> Int {
        guard keys.count >= 2 else { throw ReunionError.tooFew }
        return try await db.pool.write { conn in
            var works: [UUID] = []
            for key in keys {
                guard let row = try Row.fetchOne(conn, sql: """
                    SELECT e.workId AS w FROM edition_key k JOIN edition e ON e.id = k.editionId WHERE k.key = ? COLLATE NOCASE
                    """, arguments: [key]) else { throw ReunionError.unknownKey(key) }
                let work: UUID = row["w"]
                if !works.contains(work) { works.append(work) }
            }
            guard let keptId = works.first, var kept = try Work.fetchOne(conn, key: keptId) else { return 0 }
            var absorbed = 0
            for workId in works {
                guard let work = try Work.fetchOne(conn, key: workId) else { continue }
                // Chaque édition garde le titre sous lequel elle a paru.
                try conn.execute(sql: "UPDATE edition SET title = ? WHERE workId = ? AND (title IS NULL OR title = '')",
                                 arguments: [work.title, work.id])
                guard workId != keptId else { continue }
                try conn.execute(sql: "UPDATE edition SET workId = ? WHERE workId = ?", arguments: [keptId, workId])
                try conn.execute(sql: """
                    INSERT OR IGNORE INTO collection_item (collectionId, workId)
                    SELECT collectionId, ? FROM collection_item WHERE workId = ?
                    """, arguments: [keptId, workId])
                try CatalogStore.preserveWorkNotes(from: workId, into: keptId, in: conn)
                _ = try Work.deleteOne(conn, key: workId)
                absorbed += 1
            }
            kept = try Work.fetchOne(conn, key: keptId) ?? kept
            if kept.originalLanguage == nil,
               let language = try String.fetchOne(conn, sql: """
                   SELECT e.language FROM edition_key k JOIN edition e ON e.id = k.editionId WHERE k.key = ? COLLATE NOCASE
                   """, arguments: [keys[0]]) {
                kept.originalLanguage = language
                try kept.update(conn)
            }
            let note = "Réunion sur pièce le \(date) (\(keys.joined(separator: ", "))) : \(preuve)"
            try conn.execute(sql: """
                UPDATE work SET notes = CASE WHEN notes IS NULL OR notes = '' THEN ? ELSE notes || char(10) || ? END WHERE id = ?
                """, arguments: [note, note, keptId])
            try EditionKey.refreshProvisional(forWork: keptId, conn)
            return absorbed
        }
    }

    /// Réunit chaque groupe sous l'œuvre gardée. Rend le nombre d'œuvres absorbées.
    @discardableResult
    public static func apply(_ groups: [TranslationGroup], links: [AuthorityLink], to db: CatalogDatabase) async throws -> Int {
        try await CatalogStore(db: db).record(links)
        return try await db.pool.write { conn in
            var absorbed = 0
            for g in groups {
                guard let keptId = g.works.first?.id, var kept = try Work.fetchOne(conn, key: keptId) else { continue }
                // Chaque édition garde le titre sous lequel elle a paru.
                for member in g.works {
                    try conn.execute(sql: "UPDATE edition SET title = ? WHERE workId = ? AND (title IS NULL OR title = '')",
                                     arguments: [member.title, member.id])
                }
                for member in g.works.dropFirst() {
                    guard let work = try Work.fetchOne(conn, key: member.id), work.confidence != .high else { continue }
                    try conn.execute(sql: "UPDATE edition SET workId = ? WHERE workId = ?", arguments: [kept.id, work.id])
                    try conn.execute(sql: """
                        INSERT OR IGNORE INTO collection_item (collectionId, workId)
                        SELECT collectionId, ? FROM collection_item WHERE workId = ?
                        """, arguments: [kept.id, work.id])
                    try CatalogStore.preserveWorkNotes(from: work.id, into: kept.id, in: conn)
                    _ = try Work.deleteOne(conn, key: work.id)
                    absorbed += 1
                }
                kept = try Work.fetchOne(conn, key: kept.id) ?? kept
                // L'œuvre : son titre original et sa date, sa langue.
                if kept.confidence != .high {
                    if let original = g.originalTitle, !original.isEmpty { kept.title = original }
                    if kept.date == nil, let year = g.year { kept.date = year }
                    if let lang = g.originalLanguage { kept.originalLanguage = lang }
                    try kept.update(conn)
                }
                try EditionKey.refreshProvisional(forWork: kept.id, conn)
            }
            return absorbed
        }
    }
}
