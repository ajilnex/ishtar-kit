import Foundation

/// Premier étage de l'entonnoir d'identification : le nom de fichier.
///
/// L'entonnoir complet (invariant produit) : nom de fichier → métadonnées embarquées
/// → ISBN/DOI + catalogues publics → LLM en dernier recours. À chaque étage la fiche
/// est proposée, jamais imposée.
public enum FilenameParser {
    public struct Guess: Equatable, Sendable {
        public var title: String
        public var author: String?
        public var year: String?
        public var publisher: String?
        public var isbn13: String?
        public var confidence: GuessConfidence

        public init(
            title: String,
            author: String? = nil,
            year: String? = nil,
            publisher: String? = nil,
            isbn13: String? = nil,
            confidence: GuessConfidence
        ) {
            self.title = title
            self.author = author
            self.year = year
            self.publisher = publisher
            self.isbn13 = isbn13
            self.confidence = confidence
        }
    }

    public enum GuessConfidence: Equatable, Sendable {
        /// Le motif est net (convention connue) : proposer comme « probable ».
        case structured
        /// Rien de fiable : titre dérivé du nom brut, à faire vérifier.
        case fallback
    }

    /// Analyse le nom d'un fichier (sans son chemin).
    public static func parse(fileName: String) -> Guess {
        let stem = (fileName as NSString).deletingPathExtension

        if let guess = parseAnnasArchive(stem: stem) { return guess }
        if let guess = parseAuthorYearTitle(stem: stem) { return guess }

        let cleaned = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return Guess(title: cleaned.isEmpty ? stem : cleaned, confidence: .fallback)
    }

    /// Convention `Titre -- Auteur -- Éditeur, Année -- isbn13 XXXX -- hash -- Anna's Archive`.
    /// Les champs sont séparés par ` -- ` ; leur nombre et leur ordre varient, on reste prudent.
    private static func parseAnnasArchive(stem: String) -> Guess? {
        let parts = stem.components(separatedBy: " -- ").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 3 else { return nil }

        let title = parts[0]
        let author = parts[1].isEmpty ? nil : parts[1]
        guard !title.isEmpty else { return nil }

        var year: String?
        var isbn13: String?
        for part in parts.dropFirst(2) {
            if isbn13 == nil, let match = firstMatch(#"isbn13[ _]?(\d{13})"#, in: part) {
                isbn13 = match
            }
            if year == nil, let match = firstMatch(#"\b(1[5-9]\d{2}|20\d{2})\b"#, in: part) {
                year = match
            }
        }

        return Guess(title: title, author: author, year: year, isbn13: isbn13, confidence: .structured)
    }

    /// Convention `Auteur_Année_Titre` héritée des bibliothèques déjà rangées à la main.
    private static func parseAuthorYearTitle(stem: String) -> Guess? {
        let parts = stem.components(separatedBy: "_")
        guard parts.count >= 3 else { return nil }
        let author = parts[0].trimmingCharacters(in: .whitespaces)
        let year = parts[1].trimmingCharacters(in: .whitespaces)
        guard !author.isEmpty,
              firstMatch(#"^(1[0-9]{3}|20\d{2})[a-z]?$"#, in: year) != nil
        else { return nil }
        let title = parts.dropFirst(2).joined(separator: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return Guess(title: title, author: author, year: year, confidence: .structured)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        let rangeIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: rangeIndex), in: text) else { return nil }
        return String(text[range])
    }
}
