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
    private static func parseAuthorYearTitle(stem: String) -> MetadataGuess? {
        let parts = stem.components(separatedBy: "_")
        guard parts.count >= 3 else { return nil }
        let author = parts[0].trimmingCharacters(in: .whitespaces)
        let year = parts[1].trimmingCharacters(in: .whitespaces)
        guard !author.isEmpty,
              MetadataPatterns.firstMatch(#"^(1[0-9]{3}|20\d{2})[a-z]?$"#, in: year) != nil
        else { return nil }
        let title = parts.dropFirst(2).joined(separator: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return MetadataGuess(title: title, author: author, year: year, confidence: .structured)
    }
}
