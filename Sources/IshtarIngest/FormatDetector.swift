import Foundation
import IshtarCatalog
import ZIPFoundation

/// Ce qu'on a appris d'un fichier en le reniflant : son format réel, et s'il
/// est verrouillé.
public struct FormatProbe: Sendable, Equatable {
    /// Le format déduit du CONTENU. `nil` : rien de connu dans les premiers octets.
    public var format: DocumentFormat?
    /// Verrou éditeur détecté dans le fichier lui-même (MOBI chiffré, EPUB
    /// Adobe/LCP). Un format lisible peut porter un exemplaire illisible.
    public var isProtected: Bool
    /// Fichier vide ou tronqué au point de n'avoir plus d'en-tête.
    public var isDamaged: Bool

    public init(format: DocumentFormat? = nil, isProtected: Bool = false, isDamaged: Bool = false) {
        self.format = format
        self.isProtected = isProtected
        self.isDamaged = isDamaged
    }
}

/// Reconnaissance des formats par les octets, pas par le nom.
///
/// Une bibliothèque réelle est pleine de fichiers mal nommés : un EPUB en
/// `.pdf`, un RTF en `.doc`, un `.txt` qui est du HTML, une extension absente.
/// L'extension reste l'indice de départ — elle est juste, presque toujours, et
/// gratuite — mais le contenu tranche. Invariant n° 1 : local, déterministe,
/// sans réseau ; lecture seule, et jamais plus de quelques kilo-octets en tête
/// de fichier.
public enum FormatDetector: Sendable {
    /// Assez pour tous les en-têtes connus (le plus profond est le magic
    /// PalmDB, à l'octet 60).
    static let headerLength = 1024

    // MARK: - Point d'entrée

    /// Le format à retenir pour un fichier : le contenu quand il parle,
    /// l'extension sinon.
    ///
    /// L'extension l'emporte dans un seul cas : quand contenu et extension
    /// désignent la même famille (un ZIP peut être EPUB, CBZ, DOCX, ODT ou
    /// FBZ — le contenu sait déjà les distinguer, mais si l'inspection de
    /// l'archive échoue, `.cbz` nommé `.cbz` reste un CBZ).
    public static func resolve(fileURL: URL) -> DocumentFormat? {
        let byName = DocumentFormat(fileName: fileURL.lastPathComponent)
        let probe = probe(fileURL: fileURL)

        guard let sniffed = probe.format else { return byName }

        // « Texte brut » est un verdict FAIBLE : il dit seulement que le
        // fichier n'est pas binaire. Un tableur, un fichier de configuration
        // ou un journal lui ressemblent. Il ne promeut donc jamais une
        // extension que le catalogue ne connaît pas — sans quoi le scan
        // ramasserait la moitié du disque.
        if sniffed == .txt { return byName }

        // Le reniflage ne distingue pas MOBI d'AZW ni d'AZW3 (même conteneur) :
        // dans cette famille, le nom porte une nuance que les octets n'ont pas.
        if let byName, sameFamily(sniffed, byName) { return byName }
        return sniffed
    }

    /// Deux formats que le contenu ne peut pas départager : on garde alors ce
    /// que dit le nom, qui est plus précis.
    static func sameFamily(_ sniffed: DocumentFormat, _ named: DocumentFormat) -> Bool {
        switch sniffed {
        case .mobi, .azw3: return named == .mobi || named == .azw || named == .azw3
        default: return sniffed == named
        }
    }

    /// Renifle un fichier sans jamais l'écrire ni le charger en entier.
    public static func probe(fileURL: URL) -> FormatProbe {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return FormatProbe(isDamaged: true)
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerLength), head.count >= 8 else {
            return FormatProbe(isDamaged: true)
        }
        return probe(header: head, fileURL: fileURL, handle: handle)
    }

    /// Séparé pour être testable sur des octets seuls (`fileURL` ne sert qu'aux
    /// formats conteneurs, qu'il faut rouvrir en archive ; `handle` qu'à la
    /// famille MOBI, dont le premier enregistrement peut être loin dans le
    /// fichier — un dictionnaire compte des milliers d'enregistrements).
    static func probe(header head: Data, fileURL: URL?,
                      handle: FileHandle? = nil) -> FormatProbe {
        if head.starts(with: Array("%PDF-".utf8)) { return FormatProbe(format: .pdf) }
        if head.starts(with: [0x25, 0x21]) { return FormatProbe(format: .pdf) } // %! PostScript encapsulé

        // ZIP : EPUB, CBZ, DOCX, ODT, FBZ. Il faut ouvrir l'archive pour savoir.
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            // Raccourci : le « mimetype » d'un EPUB est stocké NON compressé en
            // première entrée, donc lisible dans les 100 premiers octets.
            if let range = head.firstRange(of: Data("mimetype".utf8)), range.lowerBound < 64 {
                let tail = head[range.upperBound...]
                if tail.starts(with: Array("application/epub+zip".utf8)) {
                    return FormatProbe(format: .epub, isProtected: hasAdobeDRM(fileURL))
                }
                if tail.starts(with: Array("application/vnd.oasis.opendocument.text".utf8)) {
                    return FormatProbe(format: .odt)
                }
            }
            // Une archive dont l'index est illisible est un fichier tronqué,
            // pas un format inconnu : la nuance change le message affiché.
            if let fileURL, (try? Archive(url: fileURL, accessMode: .read)) == nil {
                return FormatProbe(isDamaged: true)
            }
            return FormatProbe(format: zipFlavour(fileURL), isProtected: hasAdobeDRM(fileURL))
        }

        // PalmDB : MOBI, AZW, AZW3/KF8. Le magic est à l'octet 60.
        if head.count >= 68 {
            let magic = String(decoding: head[60..<68], as: UTF8.self)
            if magic == "BOOKMOBI" || magic == "TEXtREAd" {
                return mobiProbe(head, handle: handle)
            }
        }

        if head.starts(with: Array("AT&TFORM".utf8)) { return FormatProbe(format: .djvu) }
        if head.starts(with: Array("Rar!".utf8)) { return FormatProbe(format: .cbr) }
        if head.starts(with: Array("{\\rtf".utf8)) { return FormatProbe(format: .rtf) }
        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            return FormatProbe(format: .doc) // conteneur OLE2 (Word 97-2003)
        }
        // KFX : conteneur Amazon. « CONT » en tête, ou l'en-tête de ressource
        // « ‰KFX » des fragments.
        if head.starts(with: Array("CONT".utf8)) || head.starts(with: [0xEA, 0x44, 0x52, 0x4D]) {
            return FormatProbe(format: .kfx, isProtected: true)
        }

        return FormatProbe(format: textFlavour(head))
    }

    // MARK: - ZIP : distinguer les cinq

    /// Ce que contient une archive ZIP. On lit la liste des entrées, jamais leur
    /// contenu — sauf le `mimetype` d'un EPUB, minuscule.
    static func zipFlavour(_ fileURL: URL?) -> DocumentFormat? {
        guard let fileURL, let archive = try? Archive(url: fileURL, accessMode: .read) else {
            return nil
        }
        var sawImage = false
        var sawFB2 = false
        for entry in archive {
            let path = entry.path.lowercased()
            if path == "mimetype" { continue }
            if path.hasPrefix("meta-inf/container.xml") || path.hasSuffix(".opf") {
                return .epub
            }
            if path == "word/document.xml" { return .docx }
            if path == "content.xml" || path.hasPrefix("meta-inf/manifest.xml") { return .odt }
            if path.hasSuffix(".fb2") { sawFB2 = true }
            if path.hasSuffix(".jpg") || path.hasSuffix(".jpeg")
                || path.hasSuffix(".png") || path.hasSuffix(".webp") {
                sawImage = true
            }
        }
        if sawFB2 { return .fbz }
        // Un ZIP qui n'est QUE des images est une bande dessinée, quel que soit
        // son nom (.cbz, .zip, .rar mal renommé…).
        return sawImage ? .cbz : nil
    }

    /// Verrou Adobe (`META-INF/encryption.xml` + `rights.xml`) ou Readium LCP
    /// (`META-INF/license.lcpl`) : l'EPUB est bien un EPUB, mais chiffré.
    static func hasAdobeDRM(_ fileURL: URL?) -> Bool {
        guard let fileURL, let archive = try? Archive(url: fileURL, accessMode: .read) else {
            return false
        }
        return archive["META-INF/rights.xml"] != nil
            || archive["META-INF/license.lcpl"] != nil
            || archive["META-INF/encryption.xml"] != nil
    }

    // MARK: - Famille MOBI

    /// Le format et le verrou d'un PalmDB. Le champ « chiffrement » vit à
    /// l'octet 12 de l'en-tête PalmDOC, lui-même au début du premier
    /// enregistrement : 0 = libre, 1 = ancien Mobipocket, 2 = Mobipocket.
    ///
    /// Ce premier enregistrement suit la table des enregistrements, qui pèse
    /// 8 octets par entrée : dans un dictionnaire Kindle (des milliers
    /// d'entrées) il est bien au-delà de l'en-tête déjà lu. D'où la seconde
    /// lecture, ciblée — 40 octets, à la bonne adresse.
    static func mobiProbe(_ head: Data, handle: FileHandle?) -> FormatProbe {
        let base = head.startIndex
        guard head.count >= 82 else { return FormatProbe(format: .mobi) }
        let recordOffset = Int(be32(head, base + 78))
        guard recordOffset > 0 else { return FormatProbe(format: .mobi) }

        let record: Data
        let start: Int
        if head.count >= recordOffset + 40 {
            record = head
            start = base + recordOffset
        } else if let handle,
                  (try? handle.seek(toOffset: UInt64(recordOffset))) != nil,
                  let block = try? handle.read(upToCount: 40), block.count >= 40 {
            record = block
            start = block.startIndex
        } else {
            return FormatProbe(format: .mobi)
        }

        let encryption = Int(be16(record, start + 12))
        // Version MOBI ≥ 8 : c'est du KF8, donc un AZW3.
        let isKF8 = String(decoding: record[(start + 16)..<(start + 20)], as: UTF8.self) == "MOBI"
            && Int(be32(record, start + 36)) >= 8

        return FormatProbe(format: isKF8 ? .azw3 : .mobi, isProtected: encryption != 0)
    }

    // MARK: - Texte : HTML ou brut

    /// Un fichier sans magic connu : du texte, peut-être balisé. On ne se
    /// prononce que si les octets sont effectivement décodables.
    static func textFlavour(_ head: Data) -> DocumentFormat? {
        guard let string = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .isoLatin1) else { return nil }

        // Des octets de contrôle en nombre : c'est du binaire, pas du texte.
        let control = string.unicodeScalars.filter {
            $0.value < 0x09 || ($0.value > 0x0D && $0.value < 0x20)
        }
        if control.count > head.count / 20 { return nil }

        let lowered = string.lowercased()
        if lowered.contains("<fictionbook") { return .fb2 }
        if lowered.contains("<!doctype html") || lowered.contains("<html")
            || lowered.contains("<head>") || lowered.contains("<body") {
            return .html
        }
        return .txt
    }

    // MARK: - Lecture d'entiers gros-boutistes

    static func be16(_ data: Data, _ index: Int) -> UInt16 {
        guard index + 1 < data.endIndex else { return 0 }
        return UInt16(data[index]) << 8 | UInt16(data[index + 1])
    }

    static func be32(_ data: Data, _ index: Int) -> UInt32 {
        guard index + 3 < data.endIndex else { return 0 }
        return UInt32(data[index]) << 24 | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8 | UInt32(data[index + 3])
    }
}
