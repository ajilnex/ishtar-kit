import Foundation
import IshtarCatalog

/// Représente une entrée BibTeX parsée
public struct BibTeXEntry: Equatable, Sendable {
    public let key: String
    public let type: String
    public let fields: [String: String]
    
    public init(key: String, type: String, fields: [String: String]) {
        self.key = key
        self.type = type
        self.fields = fields
    }
}

/// Parseur pur pour les exports BibTeX.
public struct BibTeXParser: Sendable {
    
    /// Parse un contenu BibTeX complet en une liste d'entrées.
    public static func parse(content: String) -> [BibTeXEntry] {
        let lines = content.components(separatedBy: .newlines)
        var currentContent = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%") { continue }
            currentContent += line + "\n"
        }
        
        return parseEntries(from: currentContent)
    }
    
    private static func parseEntries(from text: String) -> [BibTeXEntry] {
        var entries: [BibTeXEntry] = []
        var scannerIndex = text.startIndex
        
        while scannerIndex < text.endIndex {
            guard let atIndex = text[scannerIndex...].firstIndex(of: "@") else { break }
            
            // Trouver le type
            guard let braceIndex = text[atIndex...].firstIndex(of: "{") else {
                scannerIndex = text.index(after: atIndex)
                continue
            }
            let typeRange = text.index(after: atIndex)..<braceIndex
            let type = String(text[typeRange]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            if type == "comment" || type == "string" {
                // Ignore ces blocs, on cherche juste le prochain @
                scannerIndex = text.index(after: atIndex)
                continue
            }
            
            // Extraire le bloc complet de l'entrée
            var braceCount = 0
            var endIndex = braceIndex
            var foundEnd = false
            
            for index in text.indices[braceIndex...] {
                let char = text[index]
                if char == "{" { braceCount += 1 }
                else if char == "}" {
                    braceCount -= 1
                    if braceCount == 0 {
                        endIndex = index
                        foundEnd = true
                        break
                    }
                }
            }
            
            if !foundEnd { break }
            
            let entryContentRange = text.index(after: braceIndex)..<endIndex
            let entryContent = String(text[entryContentRange])
            
            if let entry = parseSingleEntry(type: type, content: entryContent) {
                entries.append(entry)
            }
            
            scannerIndex = text.index(after: endIndex)
        }
        
        return entries
    }
    
    private static func parseSingleEntry(type: String, content: String) -> BibTeXEntry? {
        guard let firstComma = content.firstIndex(of: ",") else { return nil }
        let key = String(content[content.startIndex..<firstComma]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        let fieldsContent = String(content[content.index(after: firstComma)...])
        let fields = parseFields(from: fieldsContent)
        
        return BibTeXEntry(key: key, type: type, fields: fields)
    }
    
    private static func parseFields(from text: String) -> [String: String] {
        var fields: [String: String] = [:]
        var currentIndex = text.startIndex
        
        while currentIndex < text.endIndex {
            // Trouver le nom du champ (jusqu'au '=')
            guard let eqIndex = text[currentIndex...].firstIndex(of: "=") else { break }
            let key = String(text[currentIndex..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            currentIndex = text.index(after: eqIndex)
            
            // Trouver la valeur
            // Avancer jusqu'au début de la valeur
            while currentIndex < text.endIndex && text[currentIndex].isWhitespace {
                currentIndex = text.index(after: currentIndex)
            }
            if currentIndex == text.endIndex { break }
            
            let firstChar = text[currentIndex]
            var value = ""
            var valueEndIndex = currentIndex
            
            if firstChar == "{" {
                var braceCount = 0
                for index in text.indices[currentIndex...] {
                    let char = text[index]
                    if char == "{" { braceCount += 1 }
                    else if char == "}" {
                        braceCount -= 1
                        if braceCount == 0 {
                            valueEndIndex = index
                            break
                        }
                    }
                }
                if valueEndIndex < text.endIndex {
                    let valStart = text.index(after: currentIndex)
                    value = String(text[valStart..<valueEndIndex])
                    currentIndex = text.index(after: valueEndIndex)
                } else {
                    break
                }
            } else if firstChar == "\"" {
                var inQuote = true
                valueEndIndex = text.index(after: currentIndex)
                while valueEndIndex < text.endIndex {
                    let char = text[valueEndIndex]
                    if char == "\"" {
                        inQuote = false
                        break
                    }
                    valueEndIndex = text.index(after: valueEndIndex)
                }
                if !inQuote {
                    let valStart = text.index(after: currentIndex)
                    value = String(text[valStart..<valueEndIndex])
                    currentIndex = text.index(after: valueEndIndex)
                } else {
                    break
                }
            } else {
                // Valeur sans guillemets ni accolades (ex: nombres)
                guard let commaIndex = text[currentIndex...].firstIndex(of: ",") else {
                    value = String(text[currentIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    currentIndex = text.endIndex
                    if !key.isEmpty { fields[key] = cleanValue(value) }
                    break
                }
                value = String(text[currentIndex..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                currentIndex = commaIndex
            }
            
            if !key.isEmpty {
                fields[key] = cleanValue(value)
            }
            
            // Avancer après la virgule
            guard let nextComma = text[currentIndex...].firstIndex(of: ",") else { break }
            currentIndex = text.index(after: nextComma)
        }
        
        return fields
    }
    
    private static func cleanValue(_ value: String) -> String {
        // Enlever les accolades de protection : ex. {{La Généalogie}} -> {La Généalogie}
        var cleaned = value
        // Retire une couche externe d'accolades si présente autour de tout
        while cleaned.hasPrefix("{") && cleaned.hasSuffix("}") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        
        // Retrait des accolades internes de protection sans perdre le texte
        cleaned = cleaned.replacingOccurrences(of: "{", with: "")
        cleaned = cleaned.replacingOccurrences(of: "}", with: "")
        
        // Convertir les échappements LaTeX courants en Unicode
        let latexMap = [
            "\\'e": "é", "\\`a": "à", "\\^o": "ô", "\\\"u": "ü", "\\c{c}": "ç", "\\cc": "ç",
            "\\'E": "É", "\\`A": "À", "\\^O": "Ô", "\\\"U": "Ü", "\\c{C}": "Ç", "\\cC": "Ç",
            "\\'a": "á", "\\'i": "í", "\\'o": "ó", "\\'u": "ú",
            "\\`e": "è", "\\`u": "ù",
            "\\^a": "â", "\\^e": "ê", "\\^i": "î", "\\^u": "û",
            "\\\"a": "ä", "\\\"e": "ë", "\\\"i": "ï", "\\\"o": "ö",
            "\\oe": "œ", "\\OE": "Œ", "\\ae": "æ", "\\AE": "Æ",
            "--": "–", "---": "—", "\\&": "&"
        ]
        
        for (latex, unicode) in latexMap {
            cleaned = cleaned.replacingOccurrences(of: latex, with: unicode)
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    public static func normalizeAuthors(_ rawAuthors: String) -> [String] {
        return rawAuthors.components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { author in
                if author.contains(",") {
                    return author // Déjà "Nom, Prénom"
                } else {
                    let parts = author.components(separatedBy: " ")
                    if parts.count > 1 {
                        let lastName = parts.last!
                        let firstNames = parts.dropLast().joined(separator: " ")
                        return "\(lastName), \(firstNames)"
                    }
                    return author
                }
            }
    }
}
