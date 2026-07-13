import Foundation

/// Une proposition de métadonnées produite par un étage de l'entonnoir.
/// Toujours proposée, jamais imposée : l'utilisateur corrige tout.
public struct MetadataGuess: Equatable, Sendable {
    public var title: String
    public var author: String?
    public var year: String?
    public var publisher: String?
    public var language: String?
    public var isbn13: String?
    public var doi: String?
    public var confidence: GuessConfidence

    public init(
        title: String,
        author: String? = nil,
        year: String? = nil,
        publisher: String? = nil,
        language: String? = nil,
        isbn13: String? = nil,
        doi: String? = nil,
        confidence: GuessConfidence
    ) {
        self.title = title
        self.author = author
        self.year = year
        self.publisher = publisher
        self.language = language
        self.isbn13 = isbn13
        self.doi = doi
        self.confidence = confidence
    }
}

public enum GuessConfidence: Equatable, Sendable {
    /// Des champs nets ont été extraits : proposer comme « probable ».
    case structured
    /// Rien de fiable : titre de repli, à faire vérifier.
    case fallback
}

enum MetadataPatterns {
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        let rangeIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: rangeIndex), in: text) else { return nil }
        return String(text[range])
    }

    /// ISBN-13 : accepte les tirets/espaces, rend les 13 chiffres nus.
    static func isbn13(in text: String) -> String? {
        guard let raw = firstMatch(#"\b(97[89][\d \-]{10,17})\b"#, in: text) else { return nil }
        let digits = raw.filter(\.isNumber)
        return digits.count == 13 ? String(digits) : nil
    }

    static func doi(in text: String) -> String? {
        firstMatch(#"\b(10\.\d{4,9}/[^\s"'<>]+)"#, in: text)
    }

    static func year(in text: String) -> String? {
        firstMatch(#"\b(1[5-9]\d{2}|20\d{2})\b"#, in: text)
    }
}
