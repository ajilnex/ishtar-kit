import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Une œuvre selon Wikidata, avec tous les titres sous lesquels elle circule :
/// libellés dans les langues d'Europe, titre original, titres de ses éditions
/// et traductions. C'est ce qui permet de reconnaître que *Tout s'effondre* et
/// *Things Fall Apart* sont un seul livre.
public struct WikidataWork: Sendable, Equatable {
    public let qid: String
    public var titles: [String]
    /// Langue de l'œuvre (ISO 639-1), si Wikidata la donne.
    public var language: String?
    /// Année de première publication.
    public var year: String?
    /// Libellé français, sinon anglais, sinon le premier titre.
    public var label: String
    /// Libellé dans la langue de l'œuvre, s'il existe : son titre original.
    public var originalTitle: String?
}

/// Étage 3 (opt-in, réseau) : le point d'accès SPARQL de Wikidata. Décodage
/// pur, testé sans réseau.
public struct WikidataConnector: Sendable {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// Langues des libellés retenus : celles qu'une bibliothèque de recherche
    /// européenne a des chances de posséder (en écriture latine, puisque la
    /// comparaison des titres passe par l'ASCII).
    static let labelLanguages = ["fr", "en", "de", "it", "es", "pt", "la", "nl"]

    /// L'entité Wikidata d'une personne, à partir de sa notice IdRef (P269).
    public func entity(forIdRef ppn: String) async throws -> String? {
        guard IdRefConnector.isPPN(ppn) else { return nil }
        let data = try await sparql("SELECT ?p WHERE { ?p wdt:P269 \"\(ppn)\" } LIMIT 2")
        let found = Self.values(data, variable: "p").compactMap(Self.qid)
        return found.count == 1 ? found[0] : nil
    }

    /// Les œuvres d'une personne (P50), y compris celles qu'on n'atteint que
    /// par une de leurs éditions (P629).
    public func works(ofAuthor qid: String) async throws -> [WikidataWork] {
        guard Self.isQID(qid) else { return [] }
        let langs = Self.labelLanguages.map { "\"\($0)\"" }.joined(separator: ",")
        let query = """
            SELECT ?w ?t ?lang ?date WHERE {
              { ?w wdt:P50 wd:\(qid) } UNION { ?x wdt:P50 wd:\(qid) . ?x wdt:P629 ?w }
              { ?w rdfs:label ?t . FILTER(lang(?t) IN (\(langs))) }
              UNION { ?w wdt:P1476 ?t }
              UNION { ?e wdt:P629 ?w . ?e wdt:P1476 ?t }
              OPTIONAL { ?w wdt:P407 ?l . ?l wdt:P218 ?lang }
              OPTIONAL { ?w wdt:P577 ?date }
            } LIMIT 8000
            """
        return Self.parse(works: try await sparql(query))
    }

    /// Les libellés d'usage (français, sinon anglais) d'entités Wikidata,
    /// cinquante par requête : « Theodor W. Adorno », « Platon ».
    public func labels(of qids: [String]) async throws -> [String: String] {
        var result: [String: String] = [:]
        let valid = qids.filter(Self.isQID)
        for start in stride(from: 0, to: valid.count, by: 50) {
            let batch = valid[start..<min(start + 50, valid.count)]
            var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
            components?.queryItems = [
                URLQueryItem(name: "action", value: "wbgetentities"),
                URLQueryItem(name: "ids", value: batch.joined(separator: "|")),
                URLQueryItem(name: "props", value: "labels"),
                URLQueryItem(name: "languages", value: "fr|en"),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Ishtar/0.2 (bibliothèque de recherche ; https://github.com/ajilnex/ishtar-kit)",
                             forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            result.merge(Self.parse(labels: data)) { a, _ in a }
        }
        return result
    }

    static func parse(labels data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = root["entities"] as? [String: [String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for (qid, entity) in entities {
            let labels = entity["labels"] as? [String: [String: Any]] ?? [:]
            if let value = (labels["fr"] ?? labels["en"])?["value"] as? String { result[qid] = value }
        }
        return result
    }

    private func sparql(_ query: String) async throws -> Data {
        var components = URLComponents(string: "https://query.wikidata.org/sparql")
        components?.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue("Ishtar/0.2 (bibliothèque de recherche ; https://github.com/ajilnex/ishtar-kit)",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: Décodage (pur)

    static func isQID(_ value: String) -> Bool {
        value.count > 1 && value.first == "Q" && value.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// « http://www.wikidata.org/entity/Q152388 » → « Q152388 ».
    static func qid(_ uri: String) -> String? {
        guard let last = uri.split(separator: "/").last.map(String.init), isQID(last) else { return nil }
        return last
    }

    private static func bindings(_ data: Data) -> [[String: [String: Any]]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: [String: Any]]] else { return [] }
        return bindings
    }

    static func values(_ data: Data, variable: String) -> [String] {
        bindings(data).compactMap { $0[variable]?["value"] as? String }
    }

    static func parse(works data: Data) -> [WikidataWork] {
        var byQID: [String: WikidataWork] = [:]
        var order: [String] = []
        var labels: [String: [String: String]] = [:]
        for row in bindings(data) {
            guard let uri = row["w"]?["value"] as? String, let qid = qid(uri),
                  let title = row["t"]?["value"] as? String else { continue }
            if byQID[qid] == nil {
                byQID[qid] = WikidataWork(qid: qid, titles: [], language: nil, year: nil, label: title, originalTitle: nil)
                order.append(qid)
            }
            if !byQID[qid]!.titles.contains(title) { byQID[qid]!.titles.append(title) }
            if let lang = row["t"]?["xml:lang"] as? String { labels[qid, default: [:]][lang] = title }
            if let lang = row["lang"]?["value"] as? String, byQID[qid]!.language == nil {
                byQID[qid]!.language = lang
            }
            if let date = row["date"]?["value"] as? String, date.count >= 4 {
                let year = String(date.prefix(4))
                if let current = byQID[qid]!.year, current <= year { continue }
                byQID[qid]!.year = year
            }
        }
        for qid in order {
            if let l = labels[qid], let best = l["fr"] ?? l["en"] { byQID[qid]!.label = best }
            if let lang = byQID[qid]!.language { byQID[qid]!.originalTitle = labels[qid]?[lang] }
        }
        return order.compactMap { byQID[$0] }
    }
}
