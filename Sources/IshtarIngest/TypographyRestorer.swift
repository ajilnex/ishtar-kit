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

    /// Titre propre et complément du titre (RDA-FR), quand le fichier porte
    /// « Titre : sous-titre » et que la fiche n'a que le titre. La partie avant
    /// le séparateur doit être le titre de la fiche au squelette près ; rend
    /// le titre (éventuellement mieux écrit) et le sous-titre, ou nil.
    public static func restoredSubtitle(current: String, embedded: String?) -> (title: String, subtitle: String)? {
        guard let embedded = embedded?.trimmingCharacters(in: .whitespacesAndNewlines),
              !embedded.isEmpty, !isShouting(embedded), !skeleton(current).isEmpty
        else { return nil }
        for separator in [" : ", ": ", " — ", " – ", " - ", ". "] {
            guard let range = embedded.range(of: separator) else { continue }
            let head = embedded[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            var tail = embedded[range.upperBound...].trimmingCharacters(in: .whitespaces)
            // Scories des sites de téléchargement : « (Z-Library) », « (German
            // Edition) », « (Vincent Kaufmann) » en fin de titre.
            while let paren = tail.range(of: #"\s*\([^()]*\)\s*$"#, options: .regularExpression) {
                tail.removeSubrange(paren)
            }
            let lowered = tail.lowercased()
            let junk = ["z-library", "pdfdrive", "libgen", "anna's archive", "www.", ".com", ".pdf", ".epub", ".mobi", "edition)"]
            // Un texte répété deux fois de suite trahit une métadonnée bricolée.
            let words = tail.split(separator: " ")
            let doubled = words.count >= 4 && words.count % 2 == 0
                && Array(words[..<(words.count / 2)]) == Array(words[(words.count / 2)...])
            guard skeleton(head) == skeleton(current), skeleton(tail).count >= 3, tail.count <= 120,
                  !junk.contains(where: lowered.contains), !doubled
            else { continue }
            let title = richness(head) > richness(current) ? head : current
            return (title, tail)
        }
        return nil
    }

    /// Un nom d'auteur tel qu'on l'écrit sur une fiche (« Prénom Nom »), tiré
    /// d'un champ de métadonnées : sans mention entre parenthèses (dates de
    /// vie, fonction : « Tite-Live (59 av.J.-C. – 17 av.J.-C.) »,
    /// « Heinrich(Author) Meier »), la forme inversée « Nom, Prénom » remise
    /// dans l'ordre, un nom en capitales ramené à la casse ordinaire
    /// (« Erik PORGE » → « Erik Porge »). Pur.
    public static func normalizedAuthor(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: " ", options: .regularExpression)
            // Crochets d'une notice mal lue : « David] David Spiegelhalter [Spiegelhalter ».
            .replacingOccurrences(of: #"\[[^\]]*$|^[^\[]*\]"#, with: "", options: .regularExpression)
            // Dates de vie en tête : « 1040-1105 Rashi ».
            .replacingOccurrences(of: #"^\s*\d{3,4}\s*-\s*\d{3,4}\s+"#, with: "", options: .regularExpression)
            // Dates de vie à la manière des catalogues : « Deleuze, Gilles, 1925-1995 ».
            .replacingOccurrences(of: #",\s*\d{3,4}\s*-\s*(\d{3,4}|\.{0,4})\s*$"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // « Büttgen, Philippe » → « Philippe Büttgen » ; mais « Gilles Deleuze,
        // Félix Guattari » est une liste, pas une forme inversée.
        if let inverted = invertedForm(name) { name = inverted }
        return name.split(separator: " ").map { word -> String in
            let letters = word.filter(\.isLetter)
            guard letters.count > 1, letters == letters.uppercased() else { return String(word) }
            return word.lowercased().split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
        }.joined(separator: " ")
    }

    /// Particules qui restent avec le nom de famille : « Brunhoff, Suzanne de ».
    static let particles: Set<String> = ["de", "du", "des", "d", "la", "le", "von", "van", "der", "den", "di", "da", "del", "della", "ten", "ter"]

    /// « Nom, Prénom » → « Prénom Nom », si c'est bien une forme inversée :
    /// deux parties, la première d'un mot (ou deux, dont une particule), la
    /// seconde sans chiffres. Sinon nil (liste de noms, mention de dates…).
    static func invertedForm(_ name: String) -> String? {
        let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !parts[1].contains(where: \.isNumber) else { return nil }
        let family = parts[0].split(whereSeparator: \.isWhitespace).map(String.init)
        let given = parts[1].split(whereSeparator: \.isWhitespace)
        let familyOK = family.count == 1
            || (family.count == 2 && particles.contains(family[0].lowercased()))
        guard familyOK, given.count <= 4 else { return nil }
        return "\(parts[1]) \(parts[0])"
    }

    /// Plusieurs personnes dans un même champ.
    public static func isNameList(_ name: String) -> Bool {
        let lower = name.lowercased()
        if name.contains(";") || lower.contains(" and ") || name.contains(" & ") || lower.contains(" et ") { return true }
        return name.contains(",") && invertedForm(name) == nil
    }

    /// Le nom d'auteur à retenir, ou nil. Admis : la même graphie enrichie
    /// (`Buttgen` → `Büttgen`), ou le nom complet dont le dernier mot est le
    /// nom de famille connu (`Buttgen` → `Philippe Büttgen`). Jamais un autre
    /// nom de famille.
    public static func restoredAuthor(current: String, embedded: String?) -> String? {
        guard let raw = embedded?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != current, !isShouting(raw)
        else { return nil }
        // Plusieurs auteurs dans le champ : trop ambigu pour une reprise mécanique.
        if raw.contains(";") || raw.contains(" & ") || raw.lowercased().contains(" and ") { return nil }
        let embedded = normalizedAuthor(raw)
        guard !embedded.isEmpty, embedded != current else { return nil }

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
