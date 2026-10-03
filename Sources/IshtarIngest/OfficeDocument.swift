import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import IshtarCatalog
import ZIPFoundation

/// Les formats bureautiques et balisés, ramenés à leur texte.
///
/// Tous sont décodés ici même, en Swift pur, sans dépendance et sans processus
/// annexe (invariant n° 5) : un DOCX ou un ODT est une archive ZIP contenant du
/// XML, un FB2 est du XML, un RTF est du texte à échapper. Aucun n'exige de
/// moteur tiers — et aucun ne passe par AppKit, qui exigerait le fil principal
/// et rendrait le moteur intestable sans interface (invariant n° 4).
public enum OfficeDocument: Sendable {
    /// L'encodage d'une page de code Windows (`\\ansicpgNNNN` d'un RTF).
    /// Core Foundation sur macOS ; sous Linux (WP-34), la table des pages de
    /// code courantes — Windows-1252 à défaut, comme avant.
    static func rtfEncoding(codePage: UInt32) -> String.Encoding {
        #if canImport(Darwin)
        return String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertWindowsCodepageToEncoding(codePage)))
        #else
        switch codePage {
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        case 10000: return .macOSRoman
        case 65001: return .utf8
        case 28591: return .isoLatin1
        case 28592: return .isoLatin2
        default: return .windowsCP1252
        }
        #endif
    }

    /// Le texte d'un DOCX. `word/document.xml` porte le corps ; les `<w:p>`
    /// sont les paragraphes, seule structure dont l'index ait besoin.
    public static func docxText(_ url: URL) -> String? {
        guard let xml = zipEntry(url, "word/document.xml") else { return nil }
        return paragraphText(xml, paragraphTag: "p", textTag: "t")
    }

    /// Métadonnées Dublin Core d'un DOCX (`docProps/core.xml`) : le seul
    /// endroit du format où titre et auteur soient déclarés.
    public static func docxMetadata(_ url: URL) -> (title: String?, author: String?)? {
        guard let xml = zipEntry(url, "docProps/core.xml"),
              let document = try? XMLDocument(data: xml) else { return nil }
        func value(_ name: String) -> String? {
            let nodes = try? document.nodes(forXPath: "//*[local-name()='\(name)']")
            let raw = nodes?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty ?? true) ? nil : raw
        }
        return (value("title"), value("creator"))
    }

    /// Le texte d'un ODT. Même principe que le DOCX, autre nom de fichier et
    /// autre espace de noms : `content.xml`, paragraphes `<text:p>`.
    public static func odtText(_ url: URL) -> String? {
        guard let xml = zipEntry(url, "content.xml") else { return nil }
        return paragraphText(xml, paragraphTag: "p", textTag: nil)
    }

    /// Le texte d'un FB2 (XML nu) ou d'un FBZ (le même, dans un ZIP).
    public static func fictionBookText(_ url: URL, zipped: Bool) -> String? {
        let xml: Data?
        if zipped {
            xml = firstZipEntry(url) { $0.lowercased().hasSuffix(".fb2") }
        } else {
            xml = try? Data(contentsOf: url)
        }
        guard let xml else { return nil }
        // Le corps du livre est dans <body> ; <binary> porte les images en
        // base64, qu'il ne faut surtout pas verser dans l'index.
        if let document = try? XMLDocument(data: xml) {
            for node in (try? document.nodes(forXPath: "//*[local-name()='binary']")) ?? [] {
                node.detach()
            }
            let bodies = (try? document.nodes(forXPath: "//*[local-name()='body']")) ?? []
            let text = bodies.compactMap(\.stringValue).joined(separator: "\n\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return TextExtractor.stripTags(
            String(data: xml, encoding: .utf8) ?? String(decoding: xml, as: UTF8.self))
    }

    /// Métadonnées d'un FB2 : `<description><title-info>` en porte l'essentiel.
    public static func fictionBookMetadata(_ url: URL, zipped: Bool)
        -> (title: String?, author: String?)?
    {
        let xml = zipped ? firstZipEntry(url) { $0.lowercased().hasSuffix(".fb2") }
                         : try? Data(contentsOf: url)
        guard let xml, let document = try? XMLDocument(data: xml) else { return nil }

        let title = (try? document.nodes(forXPath:
            "//*[local-name()='title-info']/*[local-name()='book-title']"))?
            .first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        let authorNode = (try? document.nodes(forXPath:
            "//*[local-name()='title-info']/*[local-name()='author']"))?.first
        let parts = ["first-name", "middle-name", "last-name"].compactMap { field -> String? in
            let value = (try? authorNode?.nodes(forXPath: "*[local-name()='\(field)']"))?
                .first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        let author = parts.isEmpty ? nil : parts.joined(separator: " ")
        return (title?.isEmpty == true ? nil : title, author)
    }

    /// Le texte d'un RTF. Le format est du texte : des groupes entre accolades,
    /// des mots de contrôle en `\mot`, et le reste est le document. On retire
    /// les groupes de service (polices, couleurs, informations) et on rend les
    /// échappements `\'xx` dans la page de code déclarée.
    public static func rtfText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let source = String(data: data, encoding: .isoLatin1) else { return nil }

        // Page de code : \ansicpgNNNN, sinon Windows-1252 (le cas courant).
        var codePage: UInt32 = 1252
        if let range = source.range(of: #"\\ansicpg(\d+)"#, options: .regularExpression) {
            codePage = UInt32(source[range].dropFirst(8)) ?? 1252
        }
        let encoding = rtfEncoding(codePage: codePage)

        // Groupes purement techniques : leur contenu n'est jamais du texte.
        let skipped: Set<String> = [
            "fonttbl", "colortbl", "stylesheet", "info", "pict", "object",
            "themedata", "colorschememapping", "latentstyles", "datastore",
            "listtable", "listoverridetable", "rsidtbl", "generator", "xmlnstbl",
        ]

        var output = ""
        var skipDepth: Int?
        var depth = 0
        var pendingBytes = [UInt8]()

        // Les échappements `\'xx` sont des OCTETS : il faut les accumuler pour
        // décoder correctement les encodages multi-octets. Mais tout texte
        // ordinaire écrit ensuite doit d'abord vider cette réserve, sinon les
        // accents se retrouvent déplacés après le mot qui les suit.
        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            let data = Data(pendingBytes)
            output += String(data: data, encoding: encoding)
                ?? String(data: data, encoding: .windowsCP1252) ?? ""
            pendingBytes.removeAll(keepingCapacity: true)
        }

        func emit(_ text: String) {
            flushBytes()
            output += text
        }

        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            switch character {
            case "{":
                flushBytes()
                depth += 1
                index = source.index(after: index)
            case "}":
                flushBytes()
                if let start = skipDepth, depth <= start { skipDepth = nil }
                depth -= 1
                index = source.index(after: index)
            case "\\":
                flushBytes()
                index = source.index(after: index)
                guard index < source.endIndex else { break }
                let next = source[index]
                // Échappements littéraux et hexadécimaux.
                if next == "\\" || next == "{" || next == "}" {
                    if skipDepth == nil { emit(String(next)) }
                    index = source.index(after: index)
                    continue
                }
                if next == "'" {
                    let from = source.index(after: index)
                    let to = source.index(from, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
                    if let byte = UInt8(source[from ..< to], radix: 16), skipDepth == nil {
                        pendingBytes.append(byte)
                    }
                    index = to
                    continue
                }
                guard next.isLetter else {
                    index = source.index(after: index)
                    continue
                }
                // Mot de contrôle : lettres, puis un argument numérique signé.
                var word = ""
                while index < source.endIndex, source[index].isLetter {
                    word.append(source[index])
                    index = source.index(after: index)
                }
                var argument = ""
                if index < source.endIndex, source[index] == "-" || source[index].isNumber {
                    if source[index] == "-" { argument.append("-"); index = source.index(after: index) }
                    while index < source.endIndex, source[index].isNumber {
                        argument.append(source[index])
                        index = source.index(after: index)
                    }
                }
                // Une espace juste après le mot de contrôle en fait partie.
                if index < source.endIndex, source[index] == " " {
                    index = source.index(after: index)
                }

                if skipped.contains(word), skipDepth == nil { skipDepth = depth }
                guard skipDepth == nil else { continue }

                switch word {
                case "par", "line", "sect", "page": emit("\n\n")
                case "tab": emit("\t")
                case "u":
                    // Caractère Unicode ; le repli qui suit (\'xx ou ?) est à sauter.
                    if let scalarValue = Int(argument), (-32768...65535).contains(scalarValue) {
                        let value = scalarValue < 0 ? scalarValue + 65536 : scalarValue
                        if let scalar = Unicode.Scalar(UInt32(value)) {
                            emit(String(scalar))
                        }
                    }
                    if index < source.endIndex, source[index] == "?" {
                        index = source.index(after: index)
                    }
                default: break
                }
            case "\r", "\n":
                index = source.index(after: index)
            default:
                if skipDepth == nil { emit(String(character)) }
                index = source.index(after: index)
            }
        }
        flushBytes()

        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Le texte d'une page HTML enregistrée.
    public static func htmlText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = TextExtractor.xhtmlText(data)
        return text.isEmpty ? nil : text
    }

    // MARK: - Outils ZIP

    static func zipEntry(_ url: URL, _ path: String) -> Data? {
        guard let archive = try? Archive(url: url, accessMode: .read),
              let entry = archive[path] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }

    static func firstZipEntry(_ url: URL, where match: (String) -> Bool) -> Data? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        for entry in archive where match(entry.path) {
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            if !data.isEmpty { return data }
        }
        return nil
    }

    // MARK: - XML : le texte, paragraphe par paragraphe

    /// Rend le texte en gardant les frontières de paragraphes (double saut de
    /// ligne) : c'est sur elles que `TextExtractor.paginate` découpe ensuite.
    static func paragraphText(_ xml: Data, paragraphTag: String, textTag: String?) -> String? {
        guard let document = try? XMLDocument(data: xml) else {
            return TextExtractor.stripTags(
                String(data: xml, encoding: .utf8) ?? String(decoding: xml, as: UTF8.self))
        }
        let paragraphs = (try? document.nodes(
            forXPath: "//*[local-name()='\(paragraphTag)']")) ?? []

        var blocks: [String] = []
        for paragraph in paragraphs {
            // Un paragraphe imbriqué dans un autre serait compté deux fois.
            if paragraph.parent?.name?.hasSuffix(paragraphTag) == true { continue }
            let text: String
            if let textTag,
               let runs = try? paragraph.nodes(forXPath: ".//*[local-name()='\(textTag)']") {
                text = runs.compactMap(\.stringValue).joined()
            } else {
                text = paragraph.stringValue ?? ""
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { blocks.append(clean) }
        }
        guard !blocks.isEmpty else { return nil }
        return blocks.joined(separator: "\n\n")
    }
}
