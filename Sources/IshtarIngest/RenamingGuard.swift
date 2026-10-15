import Foundation

/// Compare le témoin du nom de fichier à la liste du catalogue sans prendre
/// une liste de coauteurs pour une seule personne.
public enum RenamingGuard {
    public static func authorsAgree(_ source: String, with authors: [String], publisher: String? = nil) -> Bool {
        guard !authors.isEmpty else { return false }
        // Les étiquettes produites par Ishtar abrègent trois auteurs ou plus.
        // Comparer le nom explicite, sans traiter « al. » comme un patronyme.
        if authors.count > 1,
           let suffix = source.range(of: #"\s+et\s+al\.?\s*$"#,
                                     options: [.regularExpression, .caseInsensitive]) {
            return authorsAgree(String(source[..<suffix.lowerBound]), with: authors, publisher: publisher)
        }
        let explicit = source.replacingOccurrences(of: #"\s+(?:&|and|et)\s+|;"#, with: ";", options: [.regularExpression, .caseInsensitive])
        var candidates: [[String]] = []
        if explicit.contains(";") {
            candidates.append(explicit.components(separatedBy: ";"))
        } else {
            candidates.append([source])
            let commas = source.components(separatedBy: ",")
            if commas.count > 1 {
                candidates.append(commas)
                if commas.count.isMultiple(of: 2) {
                    candidates.append(stride(from: 0, to: commas.count, by: 2).map {
                        commas[$0] + ", " + commas[$0 + 1]
                    })
                }
            }
        }
        func label(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
        }
        for candidate in candidates {
            let parts = candidate.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !parts.contains(where: \.isEmpty) else { continue }
            // L'éditeur n'est retiré que comme champ séparé et sur correspondance
            // exacte avec la notice ; un mot comme « Press » ne suffit jamais.
            let names = parts.filter { part in
                !(parts.count > 1 && publisher.map { !label($0).isEmpty && label($0) == label(part) } == true)
            }
            guard !names.isEmpty else { continue }
            var remaining = authors
            var agrees = true
            for name in names {
                guard let index = remaining.firstIndex(where: {
                    Reidentification.family(name) == Reidentification.family($0)
                        || (name.split(whereSeparator: \.isWhitespace).count > 1 && Reidentification.sameAuthor(name, $0))
                }) else {
                    agrees = false; break
                }
                remaining.remove(at: index)
            }
            if agrees { return true }
        }
        // Convention historique à deux noms joints par un tiret. Ne jamais
        // accepter le premier seul si le second désigne une autre personne.
        let joined = source.components(separatedBy: "-")
        if joined.count > 1, !source.contains(","), !explicit.contains(";") {
            return authorsAgree(joined.joined(separator: ";"), with: authors, publisher: publisher)
        }
        return false
    }
}
