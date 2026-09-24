import Foundation

/// Restauration typographique : rendre à un titre ou à un nom les accents,
/// apostrophes et majuscules qu'un nom de fichier lui a fait perdre
/// (`Tout seffondre` → `Tout s'effondre`), en les reprenant des métadonnées
/// que le fichier porte lui-même.
///
/// Règle de sûreté : on ne remplace **jamais un titre par un autre titre**.
/// La version du fichier n'est retenue que si, une fois accents, ponctuation,
/// espaces et casse retirés, elle est identique à celle du catalogue — c'est
/// alors la même suite de lettres, mieux écrite. Fonctions pures.
public enum TypographyRestorer {
    /// Squelette d'une chaîne : lettres et chiffres ASCII, en minuscules.
    static func skeleton(_ value: String) -> String {
        let latin = value.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? value
        return String(latin.lowercased().unicodeScalars
            .filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }

    /// La chaîne porte-t-elle plus d'écriture que son squelette ne le laisse
    /// voir : diacritiques, apostrophe, ponctuation, majuscules non initiales ?
    static func richness(_ value: String) -> Int {
        var score = 0
        for scalar in value.unicodeScalars {
            if !scalar.isASCII { score += 2 }
            else if "'’:;,.!?-–—()".unicodeScalars.contains(scalar) { score += 1 }
        }
        return score
    }

    /// Un titre en capitales d'imprimerie (`TOUT S'EFFONDRE`) n'est pas une
    /// meilleure graphie : on ne le reprend pas.
    static func isShouting(_ value: String) -> Bool {
        let letters = value.filter(\.isLetter)
        return letters.count > 3 && letters == letters.uppercased()
    }

    /// Le titre à retenir, ou nil si le catalogue doit garder le sien.
    public static func restoredTitle(current: String, embedded: String?) -> String? {
        guard let embedded = embedded?.trimmingCharacters(in: .whitespacesAndNewlines),
              !embedded.isEmpty, embedded != current, !isShouting(embedded),
              skeleton(embedded) == skeleton(current), !skeleton(current).isEmpty,
              richness(embedded) > richness(current)
        else { return nil }
        return embedded
    }

    /// Le nom d'auteur à retenir, ou nil. Admis : la même graphie enrichie
    /// (`Buttgen` → `Büttgen`), ou le nom complet dont le dernier mot est le
    /// nom de famille connu (`Buttgen` → `Philippe Büttgen`). Jamais un autre
    /// nom de famille.
    public static func restoredAuthor(current: String, embedded: String?) -> String? {
        guard var embedded = embedded?.trimmingCharacters(in: .whitespacesAndNewlines),
              !embedded.isEmpty, embedded != current, !isShouting(embedded)
        else { return nil }
        // Mentions de fonction collées au nom : « Heinrich(Author) Meier ».
        embedded = embedded.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // « Büttgen, Philippe » → « Philippe Büttgen »
        let commaParts = embedded.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if commaParts.count == 2, !commaParts[0].isEmpty, !commaParts[1].isEmpty {
            embedded = "\(commaParts[1]) \(commaParts[0])"
        }
        // Plusieurs auteurs dans le champ : trop ambigu pour une reprise mécanique.
        if embedded.contains(";") || embedded.contains(" & ") || embedded.lowercased().contains(" and ") { return nil }

        // Un nom de famille en capitales (« Erik PORGE ») : casse ordinaire.
        embedded = embedded.split(separator: " ").map { word -> String in
            let letters = word.filter(\.isLetter)
            guard letters.count > 1, letters == letters.uppercased() else { return String(word) }
            return word.lowercased().split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
        }.joined(separator: " ")
        guard embedded != current else { return nil }

        let known = skeleton(current)
        guard !known.isEmpty else { return nil }
        if skeleton(embedded) == known { return richness(embedded) > richness(current) ? embedded : nil }
        let words = embedded.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words.count <= 5, let family = words.last,
              skeleton(String(family)) == known
        else { return nil }
        return embedded
    }
}
