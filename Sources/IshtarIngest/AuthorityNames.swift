import Foundation
import GRDB
import IshtarCatalog

/// Un nom d'auteur mis à la forme de son autorité.
public struct AuthorityName: Sendable, Equatable {
    public let creatorId: UUID
    public let current: String
    /// Forme d'usage, pour présenter : « Theodor W. Adorno ».
    public let name: String
    /// Forme inversée, pour classer : « Adorno, Theodor W. ».
    public let sortName: String
}

/// Donne aux auteurs reliés à une autorité la forme de leur nom que retient
/// l'usage (libellé Wikidata, sinon la forme IdRef remise à l'endroit), et la
/// forme de classement qui en découle (NORMES §6). Deux fiches de la même
/// personne prennent le même nom et fusionnent (`renameCreator`).
public enum AuthorityNames {
    /// La forme de classement d'un nom d'usage, d'après le nom de famille de
    /// la forme autorisée (tout ce qui précède la virgule, particules
    /// comprises) : « Simone de Beauvoir » + « Beauvoir, Simone de (…) » →
    /// « Beauvoir, Simone de ». Pur.
    static func sortName(display: String, authorityLabel: String) -> String? {
        guard let familyPart = authorityLabel.components(separatedBy: ",").first?
            .replacingOccurrences(of: #"\s*\(.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces), !familyPart.isEmpty else { return nil }
        let words = display.split(whereSeparator: \.isWhitespace).map(String.init)
        let familyWords = familyPart.split(whereSeparator: \.isWhitespace).map(String.init)
        let skeleton = { (w: [String]) in w.map { TypographyRestorer.skeleton($0) }.joined() }
        // Le nom de famille, là où il figure dans la forme d'usage.
        for start in 0..<words.count {
            let end = start + familyWords.count
            guard end <= words.count, skeleton(Array(words[start..<end])) == skeleton(familyWords) else { continue }
            let given = (words[..<start] + words[end...]).joined(separator: " ")
            let family = words[start..<end].joined(separator: " ")
            return given.isEmpty ? family : "\(family), \(given)"
        }
        return nil
    }

    /// La forme IdRef remise à l'endroit, faute de libellé Wikidata :
    /// « Adorno, Theodor Wiesengrund (1903-1969) » → « Theodor Wiesengrund Adorno ».
    static func natural(authorityLabel: String) -> String {
        let bare = authorityLabel.replacingOccurrences(of: #"\s*\(.*$"#, with: "", options: .regularExpression)
        let parts = bare.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? "\(parts[1]) \(parts[0])" : bare
    }

    /// Ce qui changerait. Réseau : les libellés Wikidata.
    public static func proposals(in db: CatalogDatabase, wikidata: WikidataConnector = WikidataConnector()) async throws -> [AuthorityName] {
        let rows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT c.id AS id, c.name AS name, c.sortName AS sortName, i.label AS label, w.identifier AS qid
                FROM creator c
                JOIN authority_link i ON i.entityType = 'creator' AND i.entityId = c.id AND i.scheme = 'idref' AND i.status = 'confirmed'
                LEFT JOIN authority_link w ON w.entityType = 'creator' AND w.entityId = c.id AND w.scheme = 'wikidata' AND w.status = 'confirmed'
                """)
        }
        let labels = try await wikidata.labels(of: rows.compactMap { $0["qid"] as String? })
        var result: [AuthorityName] = []
        for row in rows {
            let current: String = row["name"]
            guard let label: String = row["label"] else { continue }
            let usual = (row["qid"] as String?).flatMap { labels[$0] }
            // Le libellé d'usage doit contenir le nom de famille de l'autorité ;
            // sinon (pseudonyme, autre écriture), la forme IdRef remise à l'endroit.
            var name = usual ?? natural(authorityLabel: label)
            var sort = sortName(display: name, authorityLabel: label)
            if sort == nil { name = natural(authorityLabel: label); sort = sortName(display: name, authorityLabel: label) }
            guard let sortForm = sort, !TypographyRestorer.isNameList(name) else { continue }
            if name != current || sortForm != (row["sortName"] as String?) {
                result.append(AuthorityName(creatorId: row["id"], current: current, name: name, sortName: sortForm))
            }
        }
        return result.sorted { $0.sortName < $1.sortName }
    }

    /// Renomme (en fusionnant les doublons de personne) et pose la forme de
    /// classement. Rend le nombre de fiches touchées.
    @discardableResult
    public static func apply(_ names: [AuthorityName], to db: CatalogDatabase) async throws -> Int {
        let store = CatalogStore(db: db)
        for n in names {
            let kept = try await store.renameCreator(n.creatorId, to: n.name)
            try await store.setSortName(n.sortName, forCreator: kept)
        }
        return names.count
    }
}
