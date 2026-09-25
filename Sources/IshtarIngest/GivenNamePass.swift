import Foundation
import GRDB
import IshtarCatalog

/// Un prénom retrouvé.
public struct GivenName: Sendable {
    public let creatorId: UUID
    public let current: String
    public let name: String
    public let sortName: String
    public let evidence: String
}

/// Étage 3 (réseau) : les auteurs réduits à leur nom de famille (« Atlan »,
/// « Sellars ») retrouvent leur prénom dans la notice Sudoc d'un de leurs
/// livres (zone 700 $b), même quand la personne n'a pas d'autorité liée. Les
/// noms qui se suffisent (Aristote, Platon, Tite-Live) sont laissés : le
/// Sudoc ne leur donne pas de prénom. Plusieurs prénoms différents pour un
/// même nom : on s'abstient.
public enum GivenNamePass {
    public static func proposals(in db: CatalogDatabase, sudoc: SudocConnector = SudocConnector()) async throws -> [GivenName] {
        let rows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT c.id AS id, c.name AS name, w.title AS title
                FROM creator c JOIN work_creator wc ON wc.creatorId = c.id AND wc.role = 'author'
                JOIN work w ON w.id = wc.workId
                WHERE c.name NOT LIKE '% %'
                  AND EXISTS (SELECT 1 FROM edition e JOIN document d ON d.editionId = e.id WHERE e.workId = w.id AND d.isMissing = 0)
                ORDER BY c.name
                """)
        }
        var titles: [UUID: (name: String, titles: [String])] = [:]
        for row in rows {
            let id: UUID = row["id"]
            titles[id, default: (row["name"], [])].titles.append(row["title"])
        }
        var result: [GivenName] = []
        for (id, entry) in titles.sorted(by: { $0.value.name < $1.value.name }) {
            let name = entry.name
            guard !Reidentification.isPlaceholder(name), !name.contains("-") || name.first?.isUppercase == true else { continue }
            // Noms qui se suffisent, ou fiches qui mêlent plusieurs personnes.
            guard !["lautreamont", "campbell"].contains(TypographyRestorer.skeleton(name)) else { continue }
            let family = TypographyRestorer.skeleton(name)
            guard family.count >= 3 else { continue }
            var found: [String: (agent: SudocAgent, title: String)] = [:]
            for title in entry.titles.prefix(3) {
                guard let records = try? await sudoc.search(title: title, author: family) else { continue }
                for r in records where AuthorityPass.sameTitle(r.title, title) {
                    // Tout rôle : auteur, directeur de publication — c'est la même personne.
                    for a in r.agents where TypographyRestorer.skeleton(a.family) == family {
                        guard let given = a.given?.trimmingCharacters(in: .whitespaces), !given.isEmpty,
                              given.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
                        found[TypographyRestorer.skeleton(given), default: (a, title)] = (a, title)
                    }
                }
                if !found.isEmpty { break }
            }
            if found.count == 1, let (agent, title) = found.values.first, let given = agent.given {
                result.append(GivenName(creatorId: id, current: name, name: "\(given) \(agent.family)",
                                        sortName: "\(agent.family), \(given)",
                                        evidence: "« \(title) » dans le Sudoc"))
                continue
            }
            guard found.isEmpty else { continue }
            // Repli : OpenLibrary (livres), puis Crossref (articles).
            for title in entry.titles.prefix(2) {
                var hit = await openLibrary(title: title, family: family)
                if hit == nil { hit = await crossref(title: title, family: family) }
                if let hit {
                    result.append(GivenName(creatorId: id, current: name, name: hit.name, sortName: hit.sort,
                                            evidence: "« \(title) » dans \(hit.source)"))
                    break
                }
            }
        }
        return result
    }

    static func get(_ url: URL?) async -> Any? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Ishtar/0.2 (bibliothèque de recherche ; https://github.com/ajilnex/ishtar-kit)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// OpenLibrary : les auteurs d'un livre de ce titre dont le nom finit par
    /// la famille cherchée ; un seul nom complet possible.
    static func openLibrary(title: String, family: String) async -> (name: String, sort: String, source: String)? {
        var c = URLComponents(string: "https://openlibrary.org/search.json")
        c?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "author", value: family),
                         URLQueryItem(name: "limit", value: "5"), URLQueryItem(name: "fields", value: "title,author_name")]
        guard let root = await get(c?.url) as? [String: Any], let docs = root["docs"] as? [[String: Any]] else { return nil }
        var names: Set<String> = []
        for d in docs {
            guard let t = d["title"] as? String, AuthorityPass.sameTitle(t, title) else { continue }
            for n in d["author_name"] as? [String] ?? [] {
                let words = n.split(separator: " ")
                if words.count >= 2, TypographyRestorer.skeleton(String(words.last!)) == family { names.insert(n) }
            }
        }
        guard names.count == 1, let n = names.first else { return nil }
        let words = n.split(separator: " ").map(String.init)
        return (n, "\(words.last!), \(words.dropLast().joined(separator: " "))", "OpenLibrary")
    }

    /// Crossref : un article de ce titre, et son auteur de cette famille.
    static func crossref(title: String, family: String) async -> (name: String, sort: String, source: String)? {
        var c = URLComponents(string: "https://api.crossref.org/works")
        c?.queryItems = [URLQueryItem(name: "query.bibliographic", value: title), URLQueryItem(name: "query.author", value: family),
                         URLQueryItem(name: "rows", value: "3"), URLQueryItem(name: "select", value: "title,author")]
        guard let root = await get(c?.url) as? [String: Any], let message = root["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let t = (item["title"] as? [String])?.first, AuthorityPass.sameTitle(t, title) else { continue }
            for a in item["author"] as? [[String: Any]] ?? [] {
                guard let f = a["family"] as? String, TypographyRestorer.skeleton(f) == family,
                      let g = a["given"] as? String, !g.isEmpty else { continue }
                return ("\(g) \(f)", "\(f), \(g)", "Crossref")
            }
        }
        return nil
    }

    /// « ROBERT KRAUT » → « Robert Kraut » ; « Jay F Rosenberg » → « Jay F. Rosenberg ».
    static func tidy(_ name: String) -> String {
        name.split(separator: " ").map { w -> String in
            var word = String(w)
            if word.count == 1, word.first!.isLetter, word.first!.isUppercase { word += "." }
            let letters = word.filter(\.isLetter)
            if letters.count > 1, letters == letters.uppercased() {
                word = word.lowercased().split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
            }
            return word
        }.joined(separator: " ")
    }

    @discardableResult
    public static func apply(_ names: [GivenName], to db: CatalogDatabase) async throws -> Int {
        let store = CatalogStore(db: db)
        for n in names {
            let kept = try await store.renameCreator(n.creatorId, to: tidy(n.name))
            try await store.setSortName(tidy(n.sortName.replacingOccurrences(of: ",", with: " ,")).replacingOccurrences(of: " ,", with: ","), forCreator: kept)
        }
        return names.count
    }
}
