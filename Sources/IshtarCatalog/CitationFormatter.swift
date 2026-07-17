import Foundation

/// Un enregistrement bibliographique minimal, découplé du schéma : l'app le
/// construit depuis une LibraryRow, le CLI depuis ce qu'il veut.
public struct CitationRecord: Sendable, Equatable {
    public var title: String
    /// Noms en ordre naturel (« Jan Assmann »).
    public var authors: [String]
    public var year: String?
    public var publisher: String?
    public var isbn13: String?
    public var doi: String?
    public init(title: String, authors: [String] = [], year: String? = nil,
                publisher: String? = nil, isbn13: String? = nil, doi: String? = nil) {
        self.title = title
        self.authors = authors
        self.year = year
        self.publisher = publisher
        self.isbn13 = isbn13
        self.doi = doi
    }
}

/// Formatage de citations et exports bibliographiques. Fonctions PURES.
/// Heuristique des noms : le DERNIER mot est le nom de famille (les
/// particules composées — « Fustel de Coulanges » — seront raffinées
/// avec les autorités, WP-NORMES).
public enum CitationFormatter {
    public enum Style: Sendable { case chicagoAuthorDate, iso690 }

    // MARK: Découpe des noms

    /// Sépare un nom en (famille, prénoms) : famille = dernier mot,
    /// prénoms = le reste (peut être vide).
    private static func split(_ name: String) -> (family: String, given: String) {
        let parts = name.split(separator: " ").map(String.init)
        guard let family = parts.last else { return ("", "") }
        return (family, parts.dropLast().joined(separator: " "))
    }

    /// Optionnel réduit à nil si vide (défense contre les champs blancs).
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    // MARK: Citations

    /// Une citation formatée pour la fiche donnée.
    public static func cite(_ record: CitationRecord, style: Style) -> String {
        switch style {
        case .chicagoAuthorDate: return chicago(record)
        case .iso690: return iso690(record)
        }
    }

    private static func chicago(_ record: CitationRecord) -> String {
        let authors = record.authors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out = ""
        if !authors.isEmpty {
            // Premier auteur inversé, les suivants en ordre naturel.
            let head: String = {
                let (family, given) = split(authors[0])
                return given.isEmpty ? family : "\(family), \(given)"
            }()
            let parts = [head] + authors.dropFirst()
            if parts.count == 1 {
                out += parts[0]
            } else {
                out += parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
            }
            out += ". "
        }
        out += (nonEmpty(record.year) ?? "s. d.") + ". "
        out += record.title + "."
        if let publisher = nonEmpty(record.publisher) {
            out += " " + publisher + "."
        }
        return out
    }

    private static func iso690(_ record: CitationRecord) -> String {
        let authors = record.authors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out = ""
        if !authors.isEmpty {
            // Tous les auteurs inversés, famille en majuscules, séparés par « ; ».
            let names = authors.map { name -> String in
                let (family, given) = split(name)
                let up = family.uppercased()
                return given.isEmpty ? up : "\(up), \(given)"
            }
            out += names.joined(separator: " ; ") + ". "
        }
        out += record.title + "."
        // Segment éditeur/année : pas de virgule orpheline ; omis si les deux manquent.
        let segment: String?
        switch (nonEmpty(record.publisher), nonEmpty(record.year)) {
        case let (publisher?, year?): segment = "\(publisher), \(year)"
        case let (publisher?, nil): segment = publisher
        case let (nil, year?): segment = year
        case (nil, nil): segment = nil
        }
        if let segment { out += " " + segment + "." }
        if let isbn = nonEmpty(record.isbn13) { out += " ISBN \(isbn)." }
        if let doi = nonEmpty(record.doi) { out += " DOI \(doi)." }
        return out
    }

    // MARK: Clé BibTeX

    /// Repli ASCII, minuscules, alphanumérique — pour clés et identifiants.
    private static func fold(_ value: String) -> String {
        String(
            value
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
        )
    }

    /// Clé : famille du premier auteur (repliée) + année ; replis : premier
    /// mot du titre / « sd » sans année.
    private static func key(for record: CitationRecord) -> String {
        let name: String
        if let first = record.authors.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            name = fold(split(first).family)
        } else {
            name = fold(record.title.split(separator: " ").first.map(String.init) ?? "")
        }
        let year = nonEmpty(record.year).map(fold) ?? "sd"
        return name + year
    }

    // MARK: BibTeX

    /// Échappe les accolades dans une valeur BibTeX.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "{", with: "\\{")
             .replacingOccurrences(of: "}", with: "\\}")
    }

    /// Une entrée BibTeX @book. Champs absents omis.
    public static func bibtexEntry(_ record: CitationRecord) -> String {
        let authors = record.authors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var fields: [(String, String)] = []
        if !authors.isEmpty {
            fields.append(("author", authors.joined(separator: " and ")))
        }
        fields.append(("title", record.title))
        if let year = nonEmpty(record.year) { fields.append(("year", year)) }
        if let publisher = nonEmpty(record.publisher) { fields.append(("publisher", publisher)) }
        if let isbn = nonEmpty(record.isbn13) { fields.append(("isbn", isbn)) }
        if let doi = nonEmpty(record.doi) { fields.append(("doi", doi)) }

        var lines = ["@book{\(key(for: record)),"]
        for (index, field) in fields.enumerated() {
            let comma = index == fields.count - 1 ? "" : ","
            lines.append("  \(field.0) = {\(escape(field.1))}\(comma)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Le catalogue en BibTeX : entrées séparées par une ligne vide.
    public static func bibtex(_ records: [CitationRecord]) -> String {
        records.map(bibtexEntry).joined(separator: "\n\n")
    }

    // MARK: CSL-JSON

    /// Le catalogue en CSL-JSON (tableau d'items type « book »).
    public static func cslJSON(_ records: [CitationRecord]) throws -> Data {
        let items: [[String: Any]] = records.map { record in
            var item: [String: Any] = ["type": "book", "id": key(for: record), "title": record.title]
            let authors = record.authors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !authors.isEmpty {
                item["author"] = authors.map { name -> [String: String] in
                    let (family, given) = split(name)
                    var author = ["family": family]
                    if !given.isEmpty { author["given"] = given }
                    return author
                }
            }
            if let year = nonEmpty(record.year), let value = Int(year) {
                item["issued"] = ["date-parts": [[value]]]
            }
            if let publisher = nonEmpty(record.publisher) { item["publisher"] = publisher }
            if let isbn = nonEmpty(record.isbn13) { item["ISBN"] = isbn }
            if let doi = nonEmpty(record.doi) { item["DOI"] = doi }
            return item
        }
        return try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys, .prettyPrinted])
    }
}
