import Foundation

/// Retrouve un passage CONTINU dans le texte d'une page, et rend sa plage exacte
/// dans le texte d'origine.
///
/// Pourquoi cette pièce : surligner une citation et surligner des termes de
/// recherche sont deux gestes différents. Chercher « Kant » veut dire « montre
/// chaque Kant » ; citer une phrase veut dire « montre CETTE phrase, une fois ».
/// Découper une citation en mots produit un damier de surbrillances qui n'est la
/// phrase de personne.
///
/// La difficulté est que le texte d'un PDF ne ressemble pas à la phrase qu'on
/// cherche : il porte des sauts de ligne, et surtout des CÉSURES — « suffi- »
/// en fin de ligne, « ciency » au début de la suivante. Le repli neutralise la
/// casse, les diacritiques, les blancs, et recolle les mots coupés, tout en
/// gardant le chemin du retour vers les positions d'origine.
public enum PassageLocator {

    /// Plage du passage dans `text`, en unités UTF-16 (ce qu'attend PDFKit pour
    /// `PDFPage.selection(for:)`). `nil` si le passage n'y est pas.
    public static func range(of quote: String, in text: String) -> NSRange? {
        let needle = fold(quote).characters
        guard !needle.isEmpty else { return nil }
        let haystack = fold(text)
        guard let found = firstIndex(of: needle, in: haystack.characters) else { return nil }

        let start = haystack.origins[found].start
        let end = haystack.origins[found + needle.count - 1].end
        return NSRange(location: start, length: end - start)
    }

    /// Vrai si le passage se trouve dans le texte. Sert à choisir une page sans
    /// avoir à calculer la plage.
    public static func contains(_ quote: String, in text: String) -> Bool {
        range(of: quote, in: text) != nil
    }

    // MARK: Repli

    /// Texte replié, et pour chaque caractère replié les bornes UTF-16 du
    /// caractère d'origine dont il provient — le chemin du retour.
    private struct Folded {
        var characters: [Character] = []
        var origins: [(start: Int, end: Int)] = []
    }

    private static func fold(_ text: String) -> Folded {
        // Bornes UTF-16 de chaque caractère, calculées une fois.
        var units: [(ch: Character, start: Int, end: Int)] = []
        units.reserveCapacity(text.count)
        var offset = 0
        for ch in text {
            let width = String(ch).utf16.count
            units.append((ch, offset, offset + width))
            offset += width
        }

        var result = Folded()
        result.characters.reserveCapacity(units.count)
        result.origins.reserveCapacity(units.count)

        var i = 0
        var pendingSpace = false
        while i < units.count {
            let unit = units[i]

            if unit.ch.isWhitespace {
                // Tout blanc, saut de ligne compris, vaut une espace unique —
                // et jamais en tête.
                pendingSpace = !result.characters.isEmpty
                i += 1
                continue
            }

            // Césure : un tiret suivi d'un saut de ligne ne coupe pas le mot.
            if unit.ch == "-" || unit.ch == "\u{00AD}",
               let resumed = wordResumes(after: i, in: units) {
                i = resumed
                pendingSpace = false
                continue
            }

            if pendingSpace {
                result.characters.append(" ")
                result.origins.append((unit.start, unit.start))
                pendingSpace = false
            }
            // Le repli d'un caractère peut en produire plusieurs (ß → ss) :
            // tous pointent vers le même caractère d'origine.
            for folded in String(unit.ch).folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
                result.characters.append(folded)
                result.origins.append((unit.start, unit.end))
            }
            i += 1
        }
        return result
    }

    /// Si le tiret en `i` est une césure de fin de ligne, rend l'indice où le mot
    /// reprend ; `nil` si c'est un vrai trait d'union (« death-drive »).
    private static func wordResumes(after i: Int,
                                    in units: [(ch: Character, start: Int, end: Int)]) -> Int? {
        var j = i + 1
        while j < units.count, units[j].ch == " " || units[j].ch == "\t" { j += 1 }
        guard j < units.count, units[j].ch.isNewline else { return nil }
        while j < units.count, units[j].ch.isWhitespace { j += 1 }
        return j
    }

    /// Recherche naïve : les pages sont courtes, la clarté prime.
    private static func firstIndex(of needle: [Character],
                                   in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for k in 0..<needle.count where haystack[start + k] != needle[k] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }
}
