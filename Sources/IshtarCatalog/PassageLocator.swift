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

    /// Plage EXACTE du passage dans `text`, en unités UTF-16 (ce qu'attend
    /// PDFKit pour `PDFPage.selection(for:)`). `nil` si le passage n'y est pas.
    ///
    /// Mode strict : à réserver à l'ancrage d'une **affirmation** — une citation
    /// que le démon présente comme vraie, un surlignement enregistré. Pour aider
    /// quelqu'un à *retrouver* un passage, voir `matches(of:in:)`.
    public static func range(of quote: String, in text: String) -> NSRange? {
        let needle = fold(quote).characters
        guard !needle.isEmpty else { return nil }
        let haystack = fold(text)
        guard let found = firstIndex(of: needle, in: haystack.characters) else { return nil }
        return nsRange(foldedStart: found, foldedEnd: found + needle.count, in: haystack)
    }

    /// Un candidat : où il est, et à quel point il ressemble à ce qu'on cherche.
    public struct Match: Sendable, Equatable {
        public let range: NSRange
        /// 1 = la phrase exacte. En dessous : la part des mots cherchés qui se
        /// trouvent dans cette zone.
        public let score: Double
    }

    /// Les zones les plus ressemblantes, de la meilleure à la moins bonne.
    ///
    /// Mode souple, pour la NAVIGATION. Un lecteur se souvient d'une phrase « à
    /// peu près » : lui refuser toute réponse parce qu'il a inversé deux mots
    /// serait absurde. On lui propose plusieurs endroits, et **c'est lui qui
    /// tranche en lisant l'original** — ce pour quoi la bibliothèque existe.
    /// Rien n'est affirmé ici, donc l'invariant n° 6 n'est pas en cause : il
    /// gouverne ce que le démon prétend, pas où l'on regarde.
    public static func matches(of quote: String, in text: String,
                              limit: Int = 5, threshold: Double = 0.5) -> [Match] {
        guard limit > 0 else { return [] }
        let needle = fold(quote)
        let haystack = fold(text)
        guard !needle.characters.isEmpty, !haystack.characters.isEmpty else { return [] }

        // L'exact d'abord : quand il est là, il n'y a rien d'autre à proposer.
        if let found = firstIndex(of: needle.characters, in: haystack.characters) {
            return [Match(range: nsRange(foldedStart: found,
                                         foldedEnd: found + needle.characters.count,
                                         in: haystack),
                          score: 1)]
        }

        let wanted = Set(tokens(needle).map(\.key))
        let field = tokens(haystack)
        guard !wanted.isEmpty, !field.isEmpty else { return [] }

        // Une fenêtre de la longueur de la phrase cherchée, promenée sur la page.
        let width = max(1, min(tokens(needle).count, field.count))
        var scored: [(start: Int, end: Int, score: Double)] = []
        for begin in 0...(field.count - width) {
            let slice = field[begin..<(begin + width)]
            let hits = Set(slice.map(\.key)).intersection(wanted).count
            let score = Double(hits) / Double(wanted.count)
            if score >= threshold { scored.append((begin, begin + width, score)) }
        }

        // Dix fenêtres décalées d'un mot désignent le même passage : ne garder
        // que la meilleure de chaque zone, sinon la page s'allume entière.
        var kept: [(start: Int, end: Int, score: Double)] = []
        for candidate in scored.sorted(by: { $0.score > $1.score }) {
            guard !kept.contains(where: { candidate.start < $0.end && $0.start < candidate.end })
            else { continue }
            kept.append(candidate)
            if kept.count == limit { break }
        }

        return kept
            .sorted { $0.score > $1.score }
            .map { candidate in
                Match(range: nsRange(foldedStart: field[candidate.start].start,
                                     foldedEnd: field[candidate.end - 1].end,
                                     in: haystack),
                      score: candidate.score)
            }
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

    /// Bornes UTF-16 d'origine d'une tranche du texte replié.
    private static func nsRange(foldedStart: Int, foldedEnd: Int,
                                in folded: Folded) -> NSRange {
        let start = folded.origins[foldedStart].start
        let end = folded.origins[foldedEnd - 1].end
        return NSRange(location: start, length: end - start)
    }

    /// Un mot du texte replié, avec sa position. `key` sert aux comparaisons :
    /// la ponctuation collée au mot (« extinction. ») ne doit pas empêcher de
    /// le reconnaître.
    private struct Token {
        let key: String
        let start: Int
        let end: Int
    }

    private static func tokens(_ folded: Folded) -> [Token] {
        var result: [Token] = []
        var i = 0
        while i < folded.characters.count {
            guard folded.characters[i] != " " else { i += 1; continue }
            let start = i
            var word = ""
            while i < folded.characters.count, folded.characters[i] != " " {
                word.append(folded.characters[i])
                i += 1
            }
            let key = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if !key.isEmpty { result.append(Token(key: key, start: start, end: i)) }
        }
        return result
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
