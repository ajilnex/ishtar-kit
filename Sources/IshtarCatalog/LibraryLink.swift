import Foundation

/// Un lien de lecture local. Il désigne une fiche connue, jamais un chemin
/// fourni par l'appelant. La clé d'édition se partage avec Rayons et Athanor.
public struct LibraryLink: Equatable, Sendable {
    public enum Reference: Equatable, Sendable {
        case document(UUID)
        case edition(String)
    }
    public let reference: Reference
    public let page: Int?
    public let quote: String?

    public init(reference: Reference, page: Int? = nil, quote: String? = nil) {
        self.reference = reference
        self.page = page.flatMap { $0 > 0 ? $0 : nil }
        self.quote = quote.map { String($0.prefix(4096)) }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "ishtar"
        switch reference {
        case .document(let id): components.host = "document"; components.path = "/\(id.uuidString)"
        case .edition(let key): components.host = "edition"; components.path = "/\(key)"
        }
        var items: [URLQueryItem] = []
        if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
        if let quote { items.append(URLQueryItem(name: "quote", value: quote)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "ishtar",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1 || (parts.count == 3 && parts[1] == "page") else { return nil }
        switch url.host?.lowercased() {
        case "document":
            guard let id = UUID(uuidString: parts[0]) else { return nil }
            reference = .document(id)
        case "edition":
            guard CiteKeyGenerator.isValidManualKey(parts[0]) else { return nil }
            reference = .edition(parts[0])
        default: return nil
        }
        let items = components.queryItems ?? []
        let rawPage = parts.count == 3 ? parts[2] : items.first(where: { $0.name == "page" })?.value
        if let rawPage {
            guard let number = Int(rawPage), number > 0 else { return nil }
            page = number
        } else { page = nil }
        quote = items.first(where: { $0.name == "quote" || $0.name == "sel" })?.value.map { String($0.prefix(4096)) }
    }

    /// Fiche privée Rayons ; les liens publics signés restent un rôle serveur.
    public static func rayonsURL(base: String, key: String) -> URL? {
        guard CiteKeyGenerator.isValidManualKey(key),
              var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        components.fragment = key
        return components.url
    }

    public static func athanorCitation(key: String) -> String? {
        guard CiteKeyGenerator.isValidManualKey(key) else { return nil }
        return "<Cite item=\"\(key)\" />"
    }
}
