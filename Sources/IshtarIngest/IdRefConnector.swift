import Foundation
import IshtarCatalog

/// Une personne trouvée dans IdRef, le référentiel d'autorités de
/// l'enseignement supérieur français (ABES).
public struct IdRefCandidate: Sendable, Equatable {
    /// Identifiant de la notice (PPN) : `026678047`.
    public let ppn: String
    /// Forme autorisée : « Adorno, Theodor Wiesengrund (1903-1969) ».
    public let label: String
}

/// Un document que le Sudoc rattache à une personne, avec son rôle.
public struct IdRefReference: Sendable, Equatable {
    public let role: String
    public let title: String
}

/// Étage 3 de l'entonnoir (opt-in, réseau) : interroge IdRef. Jamais appelé
/// par le scan ni l'ingestion (invariant n° 1) : geste volontaire. Le
/// décodage est pur et testé sans réseau.
///
/// Trois services publics, sans clé :
/// - `Sru/Solr` — recherche des notices de personnes par nom ;
/// - `services/references/<ppn>.json` — les documents liés dans le Sudoc ;
/// - `services/idref2id/<ppn>` — les correspondances (BnF, VIAF, ISNI…).
public struct IdRefConnector: Sendable {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// Les personnes dont la notice porte tous les mots du nom.
    public func search(name: String, limit: Int = 8) async throws -> [IdRefCandidate] {
        let tokens = Self.nameTokens(name)
        guard !tokens.isEmpty else { return [] }
        var components = URLComponents(string: "https://www.idref.fr/Sru/Solr")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "persname_t:(\(tokens.joined(separator: " AND ")))"),
            URLQueryItem(name: "wt", value: "json"),
            URLQueryItem(name: "fl", value: "ppn_z,affcourt_z,recordtype_z"),
            URLQueryItem(name: "rows", value: String(limit)),
        ]
        guard let url = components?.url else { return [] }
        return Self.parse(search: try await get(url))
    }

    /// Les documents du Sudoc liés à la notice (titres et rôles).
    public func references(ppn: String) async throws -> [IdRefReference] {
        guard Self.isPPN(ppn), let url = URL(string: "https://www.idref.fr/services/references/\(ppn).json") else { return [] }
        return Self.parse(references: try await get(url, timeout: 60))
    }

    /// Les correspondances de la notice vers les autres référentiels.
    public func alignments(ppn: String) async throws -> [(scheme: AuthorityLink.Scheme, identifier: String)] {
        guard Self.isPPN(ppn),
              let url = URL(string: "https://www.idref.fr/services/idref2id/\(ppn)&format=text/json") else { return [] }
        return Self.parse(alignments: try await get(url))
    }

    private func get(_ url: URL, timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Ishtar/0.2 (bibliothèque de recherche ; https://github.com/ajilnex/ishtar-kit)",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: Décodage (pur)

    static func isPPN(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 10 && value.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "X") }
    }

    /// Les mots d'un nom pour la recherche : ASCII, minuscules, au moins deux
    /// lettres (les initiales « W. » n'aident pas, elles égarent).
    static func nameTokens(_ name: String) -> [String] {
        let latin = name.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? name
        return latin.lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    static func parse(search data: Data) -> [IdRefCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let docs = response["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { doc in
            // `a` : notice de personne (les collectivités, titres… sont écartés).
            guard (doc["recordtype_z"] as? String) == "a",
                  let ppn = doc["ppn_z"] as? String, isPPN(ppn),
                  let label = doc["affcourt_z"] as? String else { return nil }
            return IdRefCandidate(ppn: ppn, label: label)
        }
    }

    /// Le service rend un objet quand il n'y a qu'un élément, un tableau
    /// sinon : on ramène tout à des tableaux.
    private static func list(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let single = value as? [String: Any] { return [single] }
        return []
    }

    static func parse(references data: Data) -> [IdRefReference] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sudoc = root["sudoc"] as? [String: Any],
              let result = sudoc["result"] as? [String: Any] else { return [] }
        var references: [IdRefReference] = []
        for role in list(result["role"]) {
            let roleName = role["roleName"] as? String ?? ""
            for doc in list(role["doc"]) {
                guard let citation = doc["citation"] as? String else { continue }
                references.append(IdRefReference(role: roleName, title: title(ofCitation: citation)))
            }
        }
        return references
    }

    /// Le titre d'une citation du Sudoc : ce qui précède la mention de
    /// responsabilité (« Minima moralia : réflexions… / Theodor W. Adorno… »).
    static func title(ofCitation citation: String) -> String {
        let head = citation.components(separatedBy: " / ").first ?? citation
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(alignments data: Data) -> [(scheme: AuthorityLink.Scheme, identifier: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var found: [(scheme: AuthorityLink.Scheme, identifier: String)] = []
        for entry in list(root["sudoc"]) {
            guard let query = entry["query"] as? [String: Any],
                  let result = query["result"] as? [String: Any],
                  let source = result["source"] as? String,
                  let raw = result["identifiant"] as? String else { continue }
            let identifier: String?
            let scheme: AuthorityLink.Scheme?
            switch source.uppercased() {
            case "BNF":
                // « http://catalogue.bnf.fr/ark:/12148/cb11888125w » → « ark:/12148/cb11888125w »
                scheme = .bnf
                identifier = raw.range(of: "ark:/").map { String(raw[$0.lowerBound...]) }
            case "VIAF":
                scheme = .viaf
                identifier = raw.split(separator: "/").last.map(String.init)
            case "ISNI":
                scheme = .isni
                identifier = raw.filter { $0.isNumber || $0 == "X" }
            default:
                scheme = nil; identifier = nil
            }
            if let scheme, let identifier, !identifier.isEmpty,
               !found.contains(where: { $0.scheme == scheme && $0.identifier == identifier }) {
                found.append((scheme, identifier))
            }
        }
        return found
    }
}
