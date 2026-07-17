import Foundation
import IshtarCatalog

/// Étage 3 de l'entonnoir (opt-in, réseau) : interroge le SRU de la BnF pour un
/// ISBN et PROPOSE des métadonnées (Dublin Core). Repli derrière OpenLibrary et
/// Google Books. Jamais appelé par le scan ni l'ingestion (invariant n° 1) :
/// geste volontaire, résultat toujours proposé, jamais enregistré seul. Le
/// décodage est pur (XMLParser) et testé sans réseau.
public struct BnFConnector: Sendable {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// GET https://catalogue.bnf.fr/api/SRU (searchRetrieve, Dublin Core, 1 notice).
    /// nil si l'ISBN est vide ou sans notice.
    public func propose(isbn: String) async throws -> MetadataGuess? {
        // Même normalisation qu'OpenLibrary : chiffres, plus un « X » final éventuel.
        let normalized = OpenLibraryConnector.normalize(isbn)
        guard !normalized.isEmpty else { return nil }

        // URLComponents encode espaces et guillemets de la requête CQL.
        var components = URLComponents(string: "https://catalogue.bnf.fr/api/SRU")
        components?.queryItems = [
            URLQueryItem(name: "version", value: "1.2"),
            URLQueryItem(name: "operation", value: "searchRetrieve"),
            URLQueryItem(name: "query", value: "bib.isbn adj \"\(normalized)\""),
            URLQueryItem(name: "recordSchema", value: "dublincore"),
            URLQueryItem(name: "maximumRecords", value: "1")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Ishtar/0.1 (https://github.com/ajilnex/ishtar-kit)",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw URLError(.badServerResponse)
        }
        return Self.parse(sruResponse: data, isbn: normalized)
    }

    /// Décodage d'une réponse SRU (Dublin Core) : pur, testable sans réseau.
    static func parse(sruResponse xml: Data, isbn: String) -> MetadataGuess? {
        let delegate = SRUDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()

        // Zéro notice annoncée, ou aucun record collecté : pas de proposition.
        if delegate.numberOfRecords == 0 { return nil }
        guard delegate.sawRecord else { return nil }

        // Titre obligatoire : pas de proposition sans titre.
        let title = delegate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        // Créateurs : « Famille, Prénoms (dates) » → « Prénoms Famille », joints par « ; ».
        var author: String?
        let names = delegate.creators
            .map(Self.naturalName)
            .filter { !$0.isEmpty }
        if !names.isEmpty { author = names.joined(separator: " ; ") }

        // Année : extraite de dc:date.
        var year: String?
        let date = delegate.date.trimmingCharacters(in: .whitespacesAndNewlines)
        if !date.isEmpty { year = MetadataPatterns.year(in: date) }

        // Éditeur et langue : champs bruts.
        let publisher = Self.cleaned(delegate.publisher)
        let language = Self.cleaned(delegate.language)

        // ISBN-13 : le paramètre s'il compte 13 chiffres, sinon nil.
        let isbn13 = isbn.filter(\.isNumber).count == 13 ? isbn : nil

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

    /// « Fustel de Coulanges, Numa Denis (1830-1889) » → « Numa Denis Fustel de Coulanges ».
    private static func naturalName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Retire une parenthèse finale de dates éventuelle.
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[name.startIndex..<open])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // « Famille, Prénoms » → « Prénoms Famille » (découpe sur la 1re virgule).
        if let comma = name.firstIndex(of: ",") {
            let family = name[name.startIndex..<comma]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let given = name[name.index(after: comma)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !given.isEmpty { return "\(given) \(family)" }
            return family
        }
        return name
    }

    /// Rend nil pour un champ vide après trim.
    private static func cleaned(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Délégué XMLParser confiné à `BnFConnector.parse` : créé, utilisé et lu dans la
/// même tâche, jamais partagé — donc pas de contrainte Sendable. Collecte les
/// champs Dublin Core du PREMIER `srw:record` seulement.
private final class SRUDelegate: NSObject, XMLParserDelegate {
    var numberOfRecords: Int?
    var sawRecord = false

    var title = ""
    var creators: [String] = []
    var date = ""
    var publisher = ""
    var language = ""

    // État interne du parcours.
    private var recordDepth = 0        // > 0 tant qu'on est dans un srw:record.
    private var finishedFirstRecord = false
    private var buffer = ""            // Texte de l'élément courant.

    /// Nom local sans préfixe de namespace : « dc:title » → « title ».
    private func localName(_ elementName: String) -> String {
        if let colon = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...])
        }
        return elementName
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        // Nouvel élément : on repart d'un tampon vide pour collecter son texte.
        buffer = ""

        if localName(elementName) == "record", !finishedFirstRecord {
            sawRecord = true
            recordDepth += 1
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        // numberOfRecords : au niveau de la réponse, hors record.
        if local == "numberOfRecords" {
            if numberOfRecords == nil { numberOfRecords = Int(text) }
            buffer = ""
            return
        }

        if local == "record" {
            if recordDepth > 0 {
                recordDepth -= 1
                if recordDepth == 0 { finishedFirstRecord = true }
            }
            buffer = ""
            return
        }

        // Champs dc : seulement dans le premier record.
        if sawRecord, !finishedFirstRecord, recordDepth > 0 {
            switch local {
            case "title":     if title.isEmpty { title = text }
            case "creator":   creators.append(text)
            case "date":      if date.isEmpty { date = text }
            case "publisher": if publisher.isEmpty { publisher = text }
            case "language":  if language.isEmpty { language = text }
            default: break
            }
        }
        buffer = ""
    }
}
