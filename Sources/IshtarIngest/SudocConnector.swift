import Foundation

/// Une personne nommée dans une notice du Sudoc (zones UNIMARC 700-702).
public struct SudocAgent: Sendable, Equatable {
    /// PPN de sa notice d'autorité IdRef (sous-zone $3), s'il est lié.
    public let ppn: String?
    public let family: String
    public let given: String?
    public let dates: String?
    /// Code de fonction UNIMARC ($4) : 070 auteur, 730 traducteur, 340 éditeur
    /// scientifique, 440 illustrateur…
    public let role: String?

    /// Forme autorisée, à la manière d'IdRef : « Adorno, Theodor Wiesengrund (1903-1969) ».
    public var label: String {
        var s = family
        if let given, !given.isEmpty { s += ", \(given)" }
        if let dates, !dates.isEmpty { s += " (\(dates))" }
        return s
    }

    public var isAuthor: Bool { role == nil || role == "070" }
    public var isTranslator: Bool { role == "730" }
}

/// Une notice bibliographique du Sudoc, réduite à ce qu'Ishtar en retient.
public struct SudocRecord: Sendable, Equatable {
    public var ppn: String
    public var title: String = ""
    public var subtitle: String?
    public var agents: [SudocAgent] = []
    /// Langue(s) du texte (zone 101 $a, ISO 639-2 : « fre », « ger »).
    public var languages: [String] = []
    /// Langue(s) de l'original, pour une traduction (zone 101 $c).
    public var originalLanguages: [String] = []
    /// Titre uniforme, c'est-à-dire le titre de l'œuvre (zone 500 $a).
    public var uniformTitle: String?
    public var year: String?

    public var isTranslation: Bool {
        !originalLanguages.isEmpty && Set(originalLanguages) != Set(languages)
    }
}

/// Étage 3 (opt-in, réseau) : le SRU du Sudoc, catalogue collectif des
/// bibliothèques universitaires françaises. On y cherche **le livre** (titre
/// et nom d'auteur) : sa notice désigne l'auteur par sa notice d'autorité
/// IdRef — c'est la preuve la plus sûre qu'un nom est cette personne-là.
/// Décodage pur (XMLParser), testé sans réseau.
public struct SudocConnector: Sendable {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// Les notices dont le titre porte ces mots et l'auteur ce nom.
    public func search(title: String, author: String, limit: Int = 5) async throws -> [SudocRecord] {
        let titleWords = IdRefConnector.nameTokens(title).prefix(6)
        let authorWords = IdRefConnector.nameTokens(author)
        guard !titleWords.isEmpty, !authorWords.isEmpty else { return [] }
        var components = URLComponents(string: "https://www.sudoc.abes.fr/cbs/sru/")
        components?.queryItems = [
            URLQueryItem(name: "operation", value: "searchRetrieve"),
            URLQueryItem(name: "version", value: "1.1"),
            URLQueryItem(name: "query", value: "mti=\(titleWords.joined(separator: " ")) and aut=\(authorWords.joined(separator: " "))"),
            URLQueryItem(name: "recordSchema", value: "unimarc"),
            URLQueryItem(name: "maximumRecords", value: String(limit)),
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Ishtar/0.2 (bibliothèque de recherche ; https://github.com/ajilnex/ishtar-kit)",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw URLError(.badServerResponse)
        }
        return Self.parse(data)
    }

    // MARK: Décodage (pur)

    static func parse(_ data: Data) -> [SudocRecord] {
        let delegate = UnimarcDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.records
    }

    private final class UnimarcDelegate: NSObject, XMLParserDelegate {
        var records: [SudocRecord] = []
        private var current: SudocRecord?
        private var tag: String?          // zone courante (datafield / controlfield)
        private var code: String?         // sous-zone courante
        private var text = ""
        private var subfields: [(String, String)] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "record": current = SudocRecord(ppn: "")
            case "controlfield", "datafield": tag = attributes["tag"]; subfields = []; text = ""
            case "subfield": code = attributes["code"]; text = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "subfield":
                if let code { subfields.append((code, text.trimmingCharacters(in: .whitespacesAndNewlines))) }
                code = nil
            case "controlfield":
                if tag == "001" { current?.ppn = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                tag = nil
            case "datafield":
                if let tag { apply(tag) }
                tag = nil
            case "record":
                if let record = current, !record.ppn.isEmpty { records.append(record) }
                current = nil
            default: break
            }
        }

        private func first(_ code: String) -> String? {
            subfields.first { $0.0 == code }.map(\.1).flatMap { $0.isEmpty ? nil : $0 }
        }

        private func all(_ code: String) -> [String] {
            subfields.filter { $0.0 == code }.map(\.1).filter { !$0.isEmpty }
        }

        private func apply(_ tag: String) {
            guard current != nil else { return }
            switch tag {
            case "101":
                current!.languages = all("a")
                current!.originalLanguages = all("c")
            case "200":
                current!.title = first("a") ?? ""
                current!.subtitle = first("e")
            case "210", "214":
                if current!.year == nil, let d = first("d") {
                    current!.year = d.firstMatch(of: /\d{4}/).map { String($0.output) }
                }
            case "500":
                if current!.uniformTitle == nil { current!.uniformTitle = first("a") }
            case "700", "701", "702":
                guard let family = first("a") else { return }
                current!.agents.append(SudocAgent(ppn: first("3"), family: family, given: first("b"),
                                                  dates: first("f"), role: first("4")))
            default: break
            }
        }
    }
}
