import Foundation
import IshtarCatalog

/// Étage 3 de l'entonnoir (opt-in, réseau) : interroge Google Books pour un ISBN
/// et PROPOSE des métadonnées. Repli de couverture derrière OpenLibrary. Jamais
/// appelé par le scan ni l'ingestion (invariant n° 1) : geste volontaire, résultat
/// toujours proposé, jamais enregistré seul. Le décodage est pur et testé sans réseau.
public struct GoogleBooksConnector: Sendable {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// GET https://www.googleapis.com/books/v1/volumes (q=isbn:<isbn>, un appel).
    /// nil si l'ISBN est vide ou sans résultat.
    public func propose(isbn: String) async throws -> MetadataGuess? {
        // Même normalisation qu'OpenLibrary : chiffres, plus un « X » final éventuel.
        let normalized = OpenLibraryConnector.normalize(isbn)
        guard !normalized.isEmpty else { return nil }

        guard let url = URL(string:
            "https://www.googleapis.com/books/v1/volumes?q=isbn:\(normalized)")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Ishtar/0.1 (https://github.com/ajilnex/ishtar-kit)",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw URLError(.badServerResponse)
        }
        return Self.parse(volumesResponse: data, isbn: normalized)
    }

    /// Décodage d'une réponse /volumes (q=isbn:…) : pur, testable sans réseau.
    static func parse(volumesResponse json: Data, isbn: String) -> MetadataGuess? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }

        // Aucun volume : pas de proposition.
        if let total = root["totalItems"] as? Int, total == 0 { return nil }
        guard let items = root["items"] as? [[String: Any]], !items.isEmpty,
              let info = items[0]["volumeInfo"] as? [String: Any]
        else { return nil }

        // Titre obligatoire : pas de proposition sans titre.
        guard let title = (info["title"] as? String),
              !title.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }

        // Auteurs : tableau de chaînes, joints par « ; ».
        var author: String?
        if let authors = info["authors"] as? [String] {
            let names = authors.filter { !$0.isEmpty }
            if !names.isEmpty { author = names.joined(separator: " ; ") }
        }

        // Année : extraite de publishedDate (ex. « 1997-03-01 » ou « 1997 »).
        var year: String?
        if let date = info["publishedDate"] as? String {
            year = MetadataPatterns.year(in: date)
        }

        // Éditeur et langue : simples champs.
        let publisher = info["publisher"] as? String
        let language = info["language"] as? String

        // ISBN-13 : le paramètre s'il compte 13 chiffres, sinon industryIdentifiers.
        var isbn13: String?
        if isbn.filter(\.isNumber).count == 13 {
            isbn13 = isbn
        } else if let ids = info["industryIdentifiers"] as? [[String: Any]],
                  let entry = ids.first(where: { $0["type"] as? String == "ISBN_13" }) {
            isbn13 = entry["identifier"] as? String
        }

        return MetadataGuess(
            title: title,
            author: author,
            year: year,
            publisher: publisher,
            language: language,
            isbn13: isbn13,
            doi: nil,
            confidence: .structured
        )
    }
}
