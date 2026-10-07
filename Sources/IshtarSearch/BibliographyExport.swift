import Foundation

/// Les références de la bibliothèque publiée, pour un outil de citation
/// (Zotero, Better BibTeX, Pandoc) et pour Athanor.
///
/// Fondé sur la publication (`CatalogPublisher.build`) : mêmes règles
/// d'exclusion, mêmes clés. Les noms viennent des formes de classement
/// d'autorité (« Beauvoir, Simone de ») ; l'année est celle de l'édition,
/// l'année de l'œuvre originale passe en `origdate` (biblatex) /
/// `original-date` (CSL). Un article (chapitre, communication) est une
/// entrée `@misc` / `article` : la bibliothèque ne connaît pas encore sa revue.
public enum BibliographyExport {
    /// (famille, prénoms) d'une personne publiée.
    static func name(_ p: PublishedPerson) -> (family: String, given: String) {
        if let sort = p.sortName, let comma = sort.firstIndex(of: ",") {
            return (String(sort[..<comma]).trimmingCharacters(in: .whitespaces),
                    String(sort[sort.index(after: comma)...]).trimmingCharacters(in: .whitespaces))
        }
        let words = p.name.split(separator: " ").map(String.init)
        guard words.count > 1 else { return (p.name, "") }
        return (words.last!, words.dropLast().joined(separator: " "))
    }

    static func people(_ e: PublishedEdition) -> [PublishedPerson] {
        e.people ?? e.authors.map { PublishedPerson(name: $0) }
    }

    /// Année lisible par un outil : « -350 » reste tel quel (biblatex l'accepte).
    static func year(_ e: PublishedEdition) -> String? { e.editionYear ?? e.year }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\textbackslash{}")
            .replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "&", with: "\\&").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "#", with: "\\#").replacingOccurrences(of: "_", with: "\\_")
    }

    /// Une entrée BibTeX/biblatex (pur).
    public static func bibtex(_ e: PublishedEdition) -> String {
        let type = e.kind == "article" ? "misc" : "book"
        var fields: [(String, String)] = []
        let names = people(e).map(name).map { $0.given.isEmpty ? $0.family : "\($0.family), \($0.given)" }
        if !names.isEmpty { fields.append(("author", names.joined(separator: " and "))) }
        fields.append(("title", e.title))
        if let s = e.subtitle, !s.isEmpty { fields.append(("subtitle", s)) }
        if let y = year(e) { fields.append(("year", y)) }
        if e.editionYear != nil, let o = e.year { fields.append(("origdate", o)) }
        if let p = e.publisher, !p.isEmpty { fields.append(("publisher", p)) }
        if let l = e.language, !l.isEmpty { fields.append(("langid", l)) }
        if let i = e.isbn13, !i.isEmpty { fields.append(("isbn", i)) }
        if let d = e.doi, !d.isEmpty { fields.append(("doi", d)) }
        // Les anciennes clés (pierres tombales) : biblatex les reconnaît comme alias.
        if let former = e.formerKeys, !former.isEmpty { fields.append(("ids", former.joined(separator: ","))) }
        var lines = ["@\(type){\(e.key),"]
        for (i, f) in fields.enumerated() {
            lines.append("  \(f.0) = {\(escape(f.1))}\(i == fields.count - 1 ? "" : ",")")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Un item CSL-JSON (pur).
    public static func csl(_ e: PublishedEdition) -> [String: Any] {
        var item: [String: Any] = ["id": e.key, "citation-key": e.key,
                                   "type": e.kind == "article" ? "article" : "book",
                                   "title": e.subtitle.map { "\(e.title) : \($0)" } ?? e.title]
        let authors = people(e).map(name).map { n -> [String: String] in
            n.given.isEmpty ? ["literal": n.family] : ["family": n.family, "given": n.given]
        }
        if !authors.isEmpty { item["author"] = authors }
        if let y = year(e), let v = Int(y) { item["issued"] = ["date-parts": [[v]]] }
        if e.editionYear != nil, let o = e.year, let v = Int(o) { item["original-date"] = ["date-parts": [[v]]] }
        if let p = e.publisher, !p.isEmpty { item["publisher"] = p }
        if let l = e.language, !l.isEmpty { item["language"] = l }
        if let i = e.isbn13, !i.isEmpty { item["ISBN"] = i }
        if let d = e.doi, !d.isEmpty { item["DOI"] = d }
        return item
    }

    public static func bibtex(_ catalogue: PublishedCatalogue) -> String {
        catalogue.editions.sorted { $0.key < $1.key }.map(bibtex).joined(separator: "\n\n") + "\n"
    }

    public static func cslJSON(_ catalogue: PublishedCatalogue) throws -> Data {
        try JSONSerialization.data(withJSONObject: catalogue.editions.sorted { $0.key < $1.key }.map(csl),
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
