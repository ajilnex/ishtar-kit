import Foundation
import IshtarCatalog

/// Lecture des livres de la famille Mobipocket : MOBI, AZW, AZW3 (KF8).
///
/// Pourquoi une implémentation maison plutôt qu'une bibliothèque : libmobi est
/// en LGPL, Calibre en GPLv3 — les deux sont exclues de l'app (60-CAP §2 :
/// BSD/MIT/Apache seulement). Le format, lui, est documenté et stable depuis
/// vingt ans. On n'en décode que ce dont Ishtar a besoin : **le texte et les
/// métadonnées**, pour l'index plein texte et l'entonnoir. L'AFFICHAGE, lui,
/// passe par foliate-js (MIT) dans la WKWebView — un seul pipeline par flux,
/// et celui-ci n'est pas celui du rendu.
///
/// Un fichier chiffré (verrou Amazon) est refusé net : `MOBIError.protected`.
/// Ishtar ne contourne aucun verrou.
public struct MOBIDocument: Sendable {
    /// Le texte du livre, balises comprises (HTML Mobipocket ou KF8).
    public let markup: String
    /// Les métadonnées EXTH utiles à l'entonnoir.
    public let metadata: MOBIMetadata

    public enum MOBIError: Error, Sendable, Equatable {
        case notMOBI
        case protected
        case unsupportedCompression(Int)
        case damaged
    }

    public struct MOBIMetadata: Sendable, Equatable {
        public var title: String?
        public var author: String?
        public var publisher: String?
        public var isbn: String?
        public var date: String?
        public var language: String?
    }

    public init(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try self.init(data: data)
    }

    public init(data: Data) throws {
        let pdb = try PalmDatabase(data: data)

        // Un fichier « combo » MOBI+KF8 range la partie KF8 après une frontière
        // annoncée par l'EXTH n° 121. On lit toujours la meilleure des deux.
        var start = 0
        var headers = try Headers(record: pdb.record(0) ?? Data())
        if headers.version < 8, let boundary = headers.exth.boundary,
           boundary < 0xFFFF_FFFF, let record = pdb.record(boundary),
           let kf8 = try? Headers(record: record) {
            headers = kf8
            start = boundary
        }

        guard headers.encryption == 0 else { throw MOBIError.protected }

        let decompress = try Self.decompressor(headers: headers, pdb: pdb, start: start)

        // Les enregistrements de texte suivent immédiatement l'en-tête.
        var bytes = Data()
        for index in 1 ... max(headers.textRecordCount, 1) {
            guard let raw = pdb.record(start + index) else { break }
            bytes.append(decompress(Self.dropTrailingEntries(raw, flags: headers.trailingFlags)))
        }
        guard !bytes.isEmpty else { throw MOBIError.damaged }

        self.markup = Self.decode(bytes, encoding: headers.encoding)
        self.metadata = headers.exth.metadata(
            fallbackTitle: headers.embeddedTitle, encoding: headers.encoding)
    }

    /// Le texte lisible : balises retirées, blancs normalisés.
    public var plainText: String {
        TextExtractor.normalizeWhitespace(TextExtractor.stripTags(markup))
    }

    // MARK: - Conteneur PalmDB

    /// Un fichier PalmDB : un en-tête, une table d'enregistrements, les données.
    struct PalmDatabase {
        let data: Data
        /// Bornes (début, fin) de chaque enregistrement.
        let bounds: [(Int, Int)]

        init(data: Data) throws {
            guard data.count >= 78 else { throw MOBIError.damaged }
            let magic = String(decoding: data[60..<68], as: UTF8.self)
            guard magic == "BOOKMOBI" || magic == "TEXtREAd" else { throw MOBIError.notMOBI }

            let count = Int(FormatDetector.be16(data, 76))
            guard count > 0, data.count >= 78 + count * 8 else { throw MOBIError.damaged }

            var offsets: [Int] = []
            offsets.reserveCapacity(count)
            for index in 0 ..< count {
                offsets.append(Int(FormatDetector.be32(data, 78 + index * 8)))
            }
            // Un offset aberrant (fichier tronqué) ne doit pas faire déborder :
            // chaque enregistrement s'arrête au suivant, ou à la fin du fichier.
            bounds = offsets.enumerated().map { index, offset in
                let end = index + 1 < offsets.count ? offsets[index + 1] : data.count
                return (offset, min(max(end, offset), data.count))
            }
            self.data = data
        }

        func record(_ index: Int) -> Data? {
            guard bounds.indices.contains(index) else { return nil }
            let (start, end) = bounds[index]
            guard start >= 0, start <= end, end <= data.count else { return nil }
            return data.subdata(in: start ..< end)
        }
    }

    // MARK: - Couverture

    /// L'image de couverture que porte le livre (JPEG, PNG ou GIF), ou nil.
    /// EXTH n° 201 donne son rang parmi les ressources, à compter du premier
    /// enregistrement d'image ; à défaut, la vignette (EXTH n° 202).
    /// Lecture seule, sans décompression du texte.
    public static func coverImage(fileURL: URL) -> Data? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let pdb = try? PalmDatabase(data: data),
              let record0 = pdb.record(0),
              let headers = try? Headers(record: record0),
              headers.firstImage >= 0
        else { return nil }
        for type in [201, 202] {
            guard let raw = headers.exth.records[type]?.first, raw.count >= 4 else { continue }
            let offset = FormatDetector.be32(raw, raw.startIndex)
            guard offset != 0xFFFF_FFFF, let image = pdb.record(headers.firstImage + Int(offset)),
                  isImage(image) else { continue }
            return image
        }
        return nil
    }

    static func isImage(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(4))
        guard b.count == 4 else { return false }
        return (b[0] == 0xFF && b[1] == 0xD8)                       // JPEG
            || (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E)       // PNG
            || (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46)       // GIF
    }

    // MARK: - En-têtes PalmDOC + MOBI + EXTH

    struct Headers {
        var compression = 0
        var textRecordCount = 0
        var encryption = 0
        var encoding = 0
        var version = 0
        var huffRecord = 0
        var huffCount = 0
        var trailingFlags = 0
        /// Premier enregistrement de ressource (images) ; 0xFFFFFFFF = aucun.
        var firstImage = -1
        var embeddedTitle: Data?
        var exth = EXTH()

        init(record: Data) throws {
            guard record.count >= 20 else { throw MOBIError.damaged }
            let base = record.startIndex
            compression = Int(FormatDetector.be16(record, base + 0))
            textRecordCount = Int(FormatDetector.be16(record, base + 8))
            encryption = Int(FormatDetector.be16(record, base + 12))

            guard String(decoding: record[(base + 16)..<(base + 20)], as: UTF8.self) == "MOBI" else {
                throw MOBIError.notMOBI
            }
            let headerLength = Int(FormatDetector.be32(record, base + 20))
            encoding = Int(FormatDetector.be32(record, base + 28))
            version = Int(FormatDetector.be32(record, base + 36))

            if record.count >= 92 {
                let titleOffset = Int(FormatDetector.be32(record, base + 84))
                let titleLength = Int(FormatDetector.be32(record, base + 88))
                if titleOffset > 0, titleLength > 0, titleLength < 1024,
                   record.count >= titleOffset + titleLength {
                    embeddedTitle = record.subdata(
                        in: (base + titleOffset) ..< (base + titleOffset + titleLength))
                }
            }
            if record.count >= 112 {
                let index = FormatDetector.be32(record, base + 108)
                firstImage = index == 0xFFFF_FFFF ? -1 : Int(index)
            }
            if record.count >= 120 {
                huffRecord = Int(FormatDetector.be32(record, base + 112))
                huffCount = Int(FormatDetector.be32(record, base + 116))
            }
            if record.count >= 244 {
                trailingFlags = Int(FormatDetector.be32(record, base + 240))
            }

            // EXTH suit l'en-tête MOBI, si le drapeau (bit 6) est levé.
            let exthFlag = record.count >= 132 ? Int(FormatDetector.be32(record, base + 128)) : 0
            if exthFlag & 0b100_0000 != 0, headerLength > 0,
               record.count > base + headerLength + 16 {
                exth = EXTH(data: record.subdata(in: (base + headerLength + 16) ..< record.endIndex))
            }
        }
    }

    /// Les enregistrements EXTH : la table de métadonnées de Mobipocket.
    struct EXTH {
        /// type → premières valeurs brutes (l'ordre des auteurs compte).
        var records: [Int: [Data]] = [:]

        init() {}

        init(data: Data) {
            let base = data.startIndex
            guard data.count >= 12,
                  String(decoding: data[base..<(base + 4)], as: UTF8.self) == "EXTH"
            else { return }

            let count = Int(FormatDetector.be32(data, base + 8))
            var offset = base + 12
            for _ in 0 ..< min(count, 512) {
                guard offset + 8 <= data.endIndex else { break }
                let type = Int(FormatDetector.be32(data, offset))
                let length = Int(FormatDetector.be32(data, offset + 4))
                guard length >= 8, offset + length <= data.endIndex else { break }
                records[type, default: []].append(
                    data.subdata(in: (offset + 8) ..< (offset + length)))
                offset += length
            }
        }

        /// EXTH n° 121 : l'enregistrement où commence la partie KF8.
        var boundary: Int? {
            guard let raw = records[121]?.first, raw.count >= 4 else { return nil }
            return Int(FormatDetector.be32(raw, raw.startIndex))
        }

        func metadata(fallbackTitle: Data?, encoding: Int) -> MOBIMetadata {
            func string(_ type: Int) -> String? {
                guard let raw = records[type]?.first else { return nil }
                let value = MOBIDocument.decode(raw, encoding: encoding)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            // Plusieurs auteurs : la fiche n'en porte qu'un, les autres
            // arrivent par la curation humaine.
            let authors = (records[100] ?? []).map {
                MOBIDocument.decode($0, encoding: encoding)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }

            return MOBIMetadata(
                title: string(503) ?? fallbackTitle.map {
                    MOBIDocument.decode($0, encoding: encoding)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                },
                author: authors.first,
                publisher: string(101),
                isbn: string(104),
                date: string(106),
                language: string(524)
            )
        }
    }

    // MARK: - Décompression

    static func decompressor(headers: Headers, pdb: PalmDatabase,
                             start: Int) throws -> @Sendable (Data) -> Data {
        switch headers.compression {
        case 1: return { $0 }
        case 2: return { decompressPalmDOC($0) }
        case 17480:
            let tables = try HuffCDIC(headers: headers, pdb: pdb, start: start)
            return { tables.decompress($0) }
        default:
            throw MOBIError.unsupportedCompression(headers.compression)
        }
    }

    /// LZ77 de PalmDOC. Quatre cas selon le premier octet : littéral, copie
    /// brute de 1 à 8 octets, paire longueur/distance, ou « espace + lettre ».
    static func decompressPalmDOC(_ input: Data) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(input.count * 3)
        let bytes = [UInt8](input)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0:
                output.append(0)
                index += 1
            case 1 ... 8:
                let run = Int(byte)
                let from = index + 1
                let to = min(from + run, bytes.count)
                output.append(contentsOf: bytes[from ..< to])
                index = from + run
            case 9 ... 0x7F:
                output.append(byte)
                index += 1
            case 0x80 ... 0xBF:
                guard index + 1 < bytes.count else { index += 1; continue }
                let pair = Int(byte) << 8 | Int(bytes[index + 1])
                let distance = (pair & 0x3FFF) >> 3
                let length = (pair & 0b111) + 3
                index += 2
                guard distance > 0, distance <= output.count else { continue }
                for _ in 0 ..< length {
                    output.append(output[output.count - distance])
                }
            default:
                output.append(0x20)
                output.append(byte ^ 0x80)
                index += 1
            }
        }
        return Data(output)
    }

    /// Les octets de queue (positions de pages, index) collés à la fin de
    /// chaque enregistrement : ils ne sont pas du texte, et leur longueur est
    /// écrite en quantité variable, à lire à l'envers.
    static func dropTrailingEntries(_ record: Data, flags: Int) -> Data {
        var data = record
        let multibyte = flags & 1
        var remaining = (flags >> 1)
        var entries = 0
        while remaining > 0 {
            entries += remaining & 1
            remaining >>= 1
        }
        for _ in 0 ..< entries {
            let length = varLengthFromEnd(data)
            guard length > 0, length <= data.count else { return data }
            data = data.subdata(in: data.startIndex ..< (data.endIndex - length))
        }
        if multibyte != 0, let last = data.last {
            let length = Int(last & 0b11) + 1
            guard length <= data.count else { return data }
            data = data.subdata(in: data.startIndex ..< (data.endIndex - length))
        }
        return data
    }

    /// Quantité de longueur variable lue depuis la fin : le bit de poids fort
    /// marque le DÉBUT de la valeur, d'où la remise à zéro en cours de route.
    static func varLengthFromEnd(_ data: Data) -> Int {
        var value = 0
        let start = max(data.startIndex, data.endIndex - 4)
        for byte in data[start ..< data.endIndex] {
            if byte & 0b1000_0000 != 0 { value = 0 }
            value = (value << 7) | Int(byte & 0b0111_1111)
        }
        return value
    }

    // MARK: - Décodage du texte

    static func decode(_ data: Data, encoding: Int) -> String {
        switch encoding {
        case 65001: String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        case 1252: String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        default: String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        }
    }
}

/// La compression HUFF/CDIC des vieux Mobipocket : un code de Huffman doublé
/// d'un dictionnaire de fragments, eux-mêmes parfois compressés.
struct HuffCDIC: Sendable {
    /// Indexée par octet de tête : (trouvé, longueur du code, valeur).
    private let table1: [(Bool, Int, UInt32)]
    /// Indexée par longueur de code : (borne inférieure, valeur maximale).
    private let table2: [(UInt32, UInt32)]
    /// Fragments du dictionnaire : (octets, déjà décompressé).
    private let dictionary: [(Data, Bool)]

    init(headers: MOBIDocument.Headers, pdb: MOBIDocument.PalmDatabase, start: Int) throws {
        guard headers.huffCount > 0,
              let huff = pdb.record(start + headers.huffRecord),
              huff.count >= 16,
              String(decoding: huff[huff.startIndex ..< (huff.startIndex + 4)], as: UTF8.self) == "HUFF"
        else { throw MOBIDocument.MOBIError.damaged }

        let base = huff.startIndex
        let offset1 = Int(FormatDetector.be32(huff, base + 8))
        let offset2 = Int(FormatDetector.be32(huff, base + 12))

        var one: [(Bool, Int, UInt32)] = []
        one.reserveCapacity(256)
        for index in 0 ..< 256 {
            let value = FormatDetector.be32(huff, base + offset1 + index * 4)
            one.append((value & 0b1000_0000 != 0, Int(value & 0b1_1111), value >> 8))
        }
        table1 = one

        var two: [(UInt32, UInt32)] = [(0, 0)]  // index 0 inutilisé (longueurs 1…32)
        for index in 0 ..< 32 {
            let at = base + offset2 + index * 8
            two.append((FormatDetector.be32(huff, at), FormatDetector.be32(huff, at + 4)))
        }
        table2 = two

        // Les CDIC suivent le HUFF : chacun porte une tranche du dictionnaire.
        var entries: [(Data, Bool)] = []
        for index in 1 ..< min(headers.huffCount, pdb.bounds.count) {
            guard let record = pdb.record(start + headers.huffRecord + index),
                  record.count >= 16,
                  String(decoding: record[record.startIndex ..< (record.startIndex + 4)],
                         as: UTF8.self) == "CDIC"
            else { continue }
            let cdicBase = record.startIndex
            let length = Int(FormatDetector.be32(record, cdicBase + 4))
            let total = Int(FormatDetector.be32(record, cdicBase + 8))
            let codeLength = Int(FormatDetector.be32(record, cdicBase + 12))
            guard length > 0, length < record.count, codeLength < 32 else { continue }

            let body = record.subdata(in: (cdicBase + length) ..< record.endIndex)
            let count = min(1 << codeLength, max(0, total - entries.count), body.count / 2)
            for slot in 0 ..< count {
                let pointer = Int(FormatDetector.be16(body, body.startIndex + slot * 2))
                guard pointer + 2 <= body.count else { continue }
                let header = FormatDetector.be16(body, body.startIndex + pointer)
                let size = Int(header & 0x7FFF)
                let isPlain = header & 0x8000 != 0
                let from = body.startIndex + pointer + 2
                guard from + size <= body.endIndex else { continue }
                entries.append((body.subdata(in: from ..< (from + size)), isPlain))
            }
        }
        guard !entries.isEmpty else { throw MOBIDocument.MOBIError.damaged }
        dictionary = entries
    }

    /// 32 bits lus à partir d'une position en BITS (le flux n'est pas aligné
    /// sur les octets). 64 bits d'accumulateur suffisent : on en consomme 32.
    private static func read32(_ bytes: [UInt8], bitPosition: Int) -> UInt32 {
        let startByte = bitPosition >> 3
        let endByte = (bitPosition + 32) >> 3
        var bits: UInt64 = 0
        for index in startByte ... endByte {
            bits = bits << 8 | UInt64(index < bytes.count ? bytes[index] : 0)
        }
        return UInt32(truncatingIfNeeded: bits >> (8 - UInt64((bitPosition + 32) & 7)))
    }

    func decompress(_ input: Data) -> Data {
        var output = Data()
        expand([UInt8](input), into: &output, depth: 0)
        return output
    }

    /// Un fragment du dictionnaire peut lui-même être compressé : la récursion
    /// est bornée (les fichiers réels ne dépassent jamais un niveau).
    private func expand(_ bytes: [UInt8], into output: inout Data, depth: Int) {
        guard depth < 4 else { return }
        let bitLength = bytes.count * 8
        var position = 0
        while position < bitLength {
            let bits = Self.read32(bytes, bitPosition: position)
            var (found, codeLength, value) = table1[Int(bits >> 24)]
            if !found {
                while codeLength < table2.count,
                      bits >> (32 - UInt32(codeLength)) < table2[codeLength].0 {
                    codeLength += 1
                }
                guard codeLength < table2.count else { return }
                value = table2[codeLength].1
            }
            guard codeLength > 0 else { return }
            position += codeLength
            guard position <= bitLength else { return }

            let code = Int(value) - Int(bits >> (32 - UInt32(codeLength)))
            guard dictionary.indices.contains(code) else { return }
            let (fragment, isPlain) = dictionary[code]
            if isPlain {
                output.append(fragment)
            } else {
                expand([UInt8](fragment), into: &output, depth: depth + 1)
            }
        }
    }
}
