import Foundation
import IshtarCatalog

/// Étage 3 de l'entonnoir (opt-in, réseau) : interroge Crossref pour un DOI
/// et PROPOSE des métadonnées. Jamais appelé par le scan ni l'ingestion
/// (invariant n° 1) : geste volontaire de l'utilisateur, résultat toujours
/// proposé, jamais enregistré seul. Le décodage est pur et testé sans réseau.
public struct CrossrefConnector: Sendable {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// GET https://api.crossref.org/works/<doi>. nil si le DOI est inconnu (404).
    public func propose(doi: String) async throws -> MetadataGuess? {
        let cleaned = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Ishtar/0.1 (https://github.com/ajilnex/ishtar-kit)",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            if http.statusCode >= 300 { throw URLError(.badServerResponse) }
        }
        return Self.parse(worksResponse: data)
    }

    /// Décodage d'une réponse /works : pur, testable sans réseau.
    static func parse(worksResponse json: Data) -> MetadataGuess? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let message = root["message"] as? [String: Any]
        else { return nil }

        // Titre obligatoire : pas de proposition sans titre.
        guard let title = (message["title"] as? [String])?
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }

        // Auteurs : « Given Family » (l'un des deux peut manquer), joints par « ; ».
        var author: String?
        if let authors = message["author"] as? [[String: Any]] {
            let names = authors.compactMap { entry -> String? in
                let parts = [entry["given"] as? String, entry["family"] as? String]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }
            if !names.isEmpty { author = names.joined(separator: " ; ") }
        }

        // Année : message.issued.date-parts[0][0].
        var year: String?
        if let issued = message["issued"] as? [String: Any],
           let dateParts = issued["date-parts"] as? [[Int]],
           let first = dateParts.first?.first {
            year = String(first)
        }

        // ISBN-13 : premier ISBN dont les chiffres nus comptent 13.
        var isbn13: String?
        if let isbns = message["ISBN"] as? [String] {
            isbn13 = isbns.compactMap { MetadataPatterns.isbn13(in: $0) }.first
        }

        return MetadataGuess(
            title: title,
            author: author,
            year: year,
            publisher: message["publisher"] as? String,
            language: message["language"] as? String,
            isbn13: isbn13,
            doi: message["DOI"] as? String,
            confidence: .structured
        )
    }
}
