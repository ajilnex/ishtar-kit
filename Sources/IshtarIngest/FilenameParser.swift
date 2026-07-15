import Foundation

/// Premier étage de l'entonnoir d'identification : le nom de fichier.
///
/// L'entonnoir complet (invariant produit) : nom de fichier → métadonnées embarquées
/// → ISBN/DOI + catalogues publics → LLM en dernier recours. À chaque étage la fiche
/// est proposée, jamais imposée.
public enum FilenameParser {
    /// Analyse le nom d'un fichier (sans son chemin).
    public static func parse(fileName: String) -> MetadataGuess {
        let stem = (fileName as NSString).deletingPathExtension

        if let guess = parseAnnasArchive(stem: stem) { return guess }
        if let guess = parseAuthorYearTitle(stem: stem) { return guess }
        if let guess = parseZLibrary(stem: stem) { return guess }
        if let guess = parseScribd(stem: stem) { return guess }

        let cleaned = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return MetadataGuess(title: cleaned.isEmpty ? stem : cleaned, confidence: .fallback)
    }

    /// Convention `Titre -- Auteur -- Éditeur, Année -- isbn13 XXXX -- hash -- Anna's Archive`.
    /// Les champs sont séparés par ` -- ` ; leur nombre et leur ordre varient, on reste prudent.
    private static func parseAnnasArchive(stem: String) -> MetadataGuess? {
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
            if isbn13 == nil, let match = MetadataPatterns.firstMatch(#"isbn13[ _]?(\d{13})"#, in: part) {
                isbn13 = match
            }
            if year == nil, let match = MetadataPatterns.year(in: part) {
                year = match
            }
        }

        return MetadataGuess(title: title, author: author, year: year, isbn13: isbn13, confidence: .structured)
    }

    /// Convention `Auteur_Année_Titre` héritée des bibliothèques déjà rangées à la main.
    /// L'année accepte les sans-date (`ND`, `SD`, `s.d.`) — fréquents pour les tapuscrits,
    /// cours et archives — et un éventuel suffixe de copie `_1`, `_2` est écarté du titre.
    private static func parseAuthorYearTitle(stem: String) -> MetadataGuess? {
        var parts = stem.components(separatedBy: "_")
        guard parts.count >= 3 else { return nil }

        // Suffixe de copie : « Celan_1959_Grille-de-parole_1 ».
        if parts.count > 3, let last = parts.last,
           last.count <= 2, last.allSatisfy(\.isNumber)
        {
            parts.removeLast()
        }

        let author = parts[0].trimmingCharacters(in: .whitespaces)
        let yearToken = parts[1].trimmingCharacters(in: .whitespaces)

        let year: String?
        if MetadataPatterns.firstMatch(#"^(1[0-9]{3}|20\d{2})[a-z]?$"#, in: yearToken) != nil {
            year = yearToken
        } else if ["nd", "n.d.", "sd", "s.d."].contains(yearToken.lowercased()) {
            year = nil
        } else {
            return nil
        }

        guard !author.isEmpty else { return nil }
        let title = parts.dropFirst(2).joined(separator: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return MetadataGuess(title: title, author: author, year: year, confidence: .structured)
    }

    /// Convention Z-Library : `Titre (Auteur) (Z-Library).ext`, parfois avec plusieurs
    /// parenthèses (année, édition) et un marqueur de copie `(1)`. Le marqueur final
    /// `(Z-Library)` / `(Z-lib.org)` est écarté ; la dernière parenthèse restante qui
    /// ressemble à un nom de personne devient l'auteur, le reste le titre. Au moindre
    /// doute sur l'auteur, on ne propose que le titre (repli honnête).
    private static func parseZLibrary(stem: String) -> MetadataGuess? {
        let groups = topLevelParentheticals(in: stem)
        guard let zIndex = groups.lastIndex(where: { isZLibraryMarker($0.content) }) else {
            return nil
        }

        // Parenthèses situées avant le marqueur Z-Library ; celles d'après
        // (marqueurs de copie « (1) ») sont ignorées.
        let preceding = Array(groups[..<zIndex])

        // Auteur : la dernière parenthèse de tête qui ressemble à un nom de personne.
        var author: String?
        var authorStart: String.Index?
        for group in preceding.reversed() {
            if let name = cleanedAuthorName(group.content) {
                author = name
                authorStart = group.start
                break
            }
        }

        // Le titre s'arrête avant l'auteur ; à défaut, avant la dernière parenthèse
        // de tête (édition/année douteuse) ou, sinon, avant le marqueur Z-Library.
        let titleCut: String.Index
        if let authorStart {
            titleCut = authorStart
        } else if let last = preceding.last {
            titleCut = last.start
        } else {
            titleCut = groups[zIndex].start
        }

        // Année : une parenthèse de tête (autre que l'auteur) contenant une année.
        var year: String?
        for group in preceding where group.start != authorStart {
            if let match = MetadataPatterns.year(in: group.content) {
                year = match
                break
            }
        }

        let title = String(stem[..<titleCut])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—•·,"))
        guard !title.isEmpty else { return nil }

        if let author {
            return MetadataGuess(title: title, author: author, year: year, confidence: .structured)
        }
        // Fichier Z-Library reconnu mais auteur douteux : repli titre propre.
        return MetadataGuess(title: title, year: year, confidence: .fallback)
    }

    /// Convention Scribd : préfixe numérique `168204597-Derrida-Jacques-La-Voix...`.
    /// L'ID de 6 à 12 chiffres est écarté, les tirets deviennent des espaces. Aucun
    /// auteur fiable : reste un repli, mais avec un titre propre (l'étage 2 fera le reste).
    private static func parseScribd(stem: String) -> MetadataGuess? {
        guard let rest = MetadataPatterns.firstMatch(#"^\d{6,12}-(.+)$"#, in: stem) else {
            return nil
        }
        var title = rest
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Suffixe bruyant laissé par certains exports : « ...-pdf », « ...-OCR ».
        title = title
            .replacingOccurrences(of: #"(?i)\s+(pdf|epub|djvu|ocr|op)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return MetadataGuess(title: title, confidence: .fallback)
    }

    /// Une parenthèse de premier niveau : son contenu et ses bornes dans la chaîne.
    /// Le suivi de profondeur gère les parenthèses nichées (`Richard Webb (editor)`).
    private struct Parenthetical {
        let content: String
        let start: String.Index
    }

    private static func topLevelParentheticals(in text: String) -> [Parenthetical] {
        var result: [Parenthetical] = []
        var depth = 0
        var open: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "(":
                if depth == 0 { open = index }
                depth += 1
            case ")":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let open {
                        let contentStart = text.index(after: open)
                        result.append(Parenthetical(
                            content: String(text[contentStart..<index]),
                            start: open
                        ))
                    }
                }
            default:
                break
            }
            index = text.index(after: index)
        }
        return result
    }

    private static func isZLibraryMarker(_ content: String) -> Bool {
        let token = content.trimmingCharacters(in: .whitespaces)
        return MetadataPatterns.firstMatch(#"^z-?lib(rary|\.org)?$"#, in: token) != nil
    }

    /// Nettoie et valide un candidat auteur tiré d'une parenthèse. Rend `nil` au
    /// moindre doute (nombre, année, marqueur d'édition, énumération trop longue).
    private static func cleanedAuthorName(_ raw: String) -> String? {
        var name = raw
            // Doublons entre crochets : « Derrida, Jacques [Derrida, Jacques] ».
            .replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
            // Annotations nichées : « (editor) », « (etc.) ».
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            // Suffixes bruyants fréquents.
            .replacingOccurrences(
                of: #"(?i)[,\s]+(etc\.?|anthologies?|collectif|editors?|eds?\.?)\s*$"#,
                with: "", options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;-"))

        guard !name.isEmpty,
              name.rangeOfCharacter(from: .letters) != nil,
              MetadataPatterns.firstMatch(#"^\d+$"#, in: name) == nil,
              // Une année cachée trahit un éditeur/année, pas une personne.
              MetadataPatterns.year(in: name) == nil,
              // Marqueurs de langue/édition (« French Edition », « Nouvelle édition »).
              MetadataPatterns.firstMatch(#"[eé]dition$"#, in: name) == nil
        else { return nil }

        let words = name.split(separator: " ")
        guard (1...6).contains(words.count) else { return nil }
        return name
    }
}
