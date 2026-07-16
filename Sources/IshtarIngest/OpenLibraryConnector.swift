import Foundation
import IshtarCatalog

/// Étage 3 de l'entonnoir (opt-in, réseau) : interroge OpenLibrary pour un ISBN
/// et PROPOSE des métadonnées. Jamais appelé par le scan ni l'ingestion
/// (invariant n° 1) : geste volontaire de l'utilisateur, résultat toujours
/// proposé, jamais enregistré seul. Le décodage est pur et testé sans réseau.
public struct OpenLibraryConnector: Sendable {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// GET https://openlibrary.org/api/books (jscmd=data, un seul appel).
    /// nil si l'ISBN est vide ou inconnu (OpenLibrary rend 200 + objet vide).
    public func propose(isbn: String) async throws -> MetadataGuess? {
        // Normalise : chiffres seulement, plus un « X » final éventuel (ISBN-10).
        let normalized = Self.normalize(isbn)
        guard !normalized.isEmpty else { return nil }

        guard let url = URL(string:
            "https://openlibrary.org/api/books?bibkeys=ISBN:\(normalized)&format=json&jscmd=data")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Ishtar/0.1 (https://github.com/ajilnex/ishtar-kit)",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw URLError(.badServerResponse)
        }
        return Self.parse(booksResponse: data, isbn: normalized)
    }

    /// ISBN normalisé : chiffres, plus un « X » final majuscule (ISBN-10).
    static func normalize(_ isbn: String) -> String {
        var digits = isbn.filter(\.isNumber)
        if let last = isbn.last, last == "X" || last == "x" { digits.append("X") }
        return digits
    }

    /// Décodage d'une réponse /api/books (jscmd=data) : pur, testable sans réseau.
    static func parse(booksResponse json: Data, isbn: String) -> MetadataGuess? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }

        // Entrée « ISBN:<isbn> » ; sinon, tolérance : la première valeur-objet.
        let entry = (root["ISBN:\(isbn)"] as? [String: Any])
            ?? root.values.compactMap { $0 as? [String: Any] }.first
        guard let entry else { return nil }

        // Titre obligatoire : pas de proposition sans titre.
        guard let title = (entry["title"] as? String),
              !title.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }

        // Auteurs : tableau d'objets « {"name": …} », joints par « ; ».
        var author: String?
        if let authors = entry["authors"] as? [[String: Any]] {
            let names = authors.compactMap { $0["name"] as? String }
                .filter { !$0.isEmpty }
            if !names.isEmpty { author = names.joined(separator: " ; ") }
        }

        // Année : extraite de publish_date (ex. « March 1997 »).
        var year: String?
        if let date = entry["publish_date"] as? String {
            year = MetadataPatterns.year(in: date)
        }

        // Éditeur : premier publishers[].name.
        let publisher = (entry["publishers"] as? [[String: Any]])?
            .first?["name"] as? String

        // ISBN-13 : le paramètre s'il compte 13 chiffres, sinon identifiers.isbn_13[0].
        var isbn13: String?
        if isbn.filter(\.isNumber).count == 13 {
            isbn13 = isbn
        } else if let ids = entry["identifiers"] as? [String: Any],
                  let list = ids["isbn_13"] as? [String],
                  let first = list.first(where: { $0.filter(\.isNumber).count == 13 }) {
            isbn13 = first.filter(\.isNumber)
        }

        return MetadataGuess(
            title: title,
            author: author,
            year: year,
            publisher: publisher,
            language: nil,   // OpenLibrary ne le donne pas simplement ici.
            isbn13: isbn13,
            doi: nil,
            confidence: .structured
        )
    }
}
