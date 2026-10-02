import Foundation

/// Les vieux `.doc` binaires (Word 97-2003).
///
/// Ils n'ont rien d'un ZIP : ce sont des « conteneurs composés » OLE2, un
/// système de fichiers miniature avec sa table d'allocation. Les seuls
/// décodeurs tout faits sont GPL (antiword, LibreOffice) ou passent par AppKit,
/// qui exige le fil principal et interdirait de tester le moteur sans
/// interface. On en lit donc ici le strict nécessaire : le flux
/// « WordDocument », sa table de morceaux, et le texte qu'elle désigne.
///
/// Aucune mise en forme n'est reconstituée — l'index plein texte n'en a pas
/// besoin, et le lecteur affiche ce texte tel quel.
enum LegacyWordDocument {
    static func text(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let container = CompoundFile(data: data),
              let document = container.stream(named: "WordDocument"),
              document.count >= 0x1A6
        else { return nil }

        // wIdent : 0xA5EC pour tous les Word binaires.
        guard le16(document, 0) == 0xA5EC else { return nil }

        // Le bit 9 des drapeaux dit laquelle des deux tables sert.
        let flags = le16(document, 0x0A)
        let tableName = (flags & 0x0200) != 0 ? "1Table" : "0Table"

        // Word 97+ : la table de morceaux (piece table) dit où est le texte et
        // dans quel encodage. Sans elle, on est sur un Word 6/95, dont le texte
        // est d'un seul tenant entre fcMin et fcMac.
        guard let table = container.stream(named: tableName) else {
            return legacyFlatText(document)
        }
        let clxOffset = Int(le32(document, 0x01A2))
        let clxLength = Int(le32(document, 0x01A6))
        guard clxLength > 0, clxOffset >= 0, clxOffset + clxLength <= table.count else {
            return legacyFlatText(document)
        }

        let clx = table.subdata(in: (table.startIndex + clxOffset) ..< (table.startIndex + clxOffset + clxLength))
        guard let pieces = pieceTable(clx) else { return legacyFlatText(document) }

        var output = ""
        for piece in pieces {
            output += pieceText(document, piece)
        }
        return clean(output)
    }

    // MARK: - Table de morceaux

    /// Un morceau de texte : où il commence dans le flux, combien de caractères,
    /// et s'il est en octets simples (Windows-1252) ou en UTF-16.
    struct Piece {
        let offset: Int
        let characterCount: Int
        let isCompressed: Bool
    }

    /// Le CLX est une suite de blocs préfixés : 0x01 = jeu de propriétés (à
    /// sauter), 0x02 = la table de morceaux elle-même.
    static func pieceTable(_ clx: Data) -> [Piece]? {
        var index = clx.startIndex
        while index < clx.endIndex {
            let kind = clx[index]
            if kind == 0x01 {
                guard index + 3 <= clx.endIndex else { return nil }
                let size = Int(le16(clx, index - clx.startIndex + 1))
                index += 3 + size
            } else if kind == 0x02 {
                guard index + 5 <= clx.endIndex else { return nil }
                let size = Int(le32(clx, index - clx.startIndex + 1))
                let from = index + 5
                guard size > 0, from + size <= clx.endIndex else { return nil }
                return descriptors(clx.subdata(in: from ..< (from + size)))
            } else {
                return nil
            }
        }
        return nil
    }

    /// Un PlcPcd : (n+1) positions de caractères sur 4 octets, puis n
    /// descripteurs de 8 octets. La taille totale donne n.
    static func descriptors(_ plc: Data) -> [Piece]? {
        // 4 * (n + 1) + 8 * n = taille  ⟹  n = (taille - 4) / 12
        let count = (plc.count - 4) / 12
        guard count > 0 else { return nil }

        var pieces: [Piece] = []
        pieces.reserveCapacity(count)
        for index in 0 ..< count {
            let cpStart = Int(le32(plc, index * 4))
            let cpEnd = Int(le32(plc, (index + 1) * 4))
            let descriptor = 4 * (count + 1) + index * 8
            guard cpEnd > cpStart, descriptor + 8 <= plc.count else { continue }

            let fc = le32(plc, descriptor + 2)
            // Bit 30 levé : texte en octets simples, et l'adresse est doublée.
            let isCompressed = (fc & 0x4000_0000) != 0
            let offset = isCompressed ? Int(fc & ~0x4000_0000) / 2 : Int(fc)
            pieces.append(Piece(offset: offset,
                                characterCount: cpEnd - cpStart,
                                isCompressed: isCompressed))
        }
        return pieces.isEmpty ? nil : pieces
    }

    static func pieceText(_ stream: Data, _ piece: Piece) -> String {
        let width = piece.isCompressed ? 1 : 2
        let byteCount = piece.characterCount * width
        let from = stream.startIndex + piece.offset
        guard piece.offset >= 0, from + byteCount <= stream.endIndex else { return "" }
        let slice = stream.subdata(in: from ..< (from + byteCount))
        if piece.isCompressed {
            return String(data: slice, encoding: .windowsCP1252) ?? ""
        }
        return String(data: slice, encoding: .utf16LittleEndian) ?? ""
    }

    /// Word 6/95 : pas de table de morceaux, le texte est un bloc continu.
    static func legacyFlatText(_ document: Data) -> String? {
        let from = Int(le32(document, 0x18))
        let to = Int(le32(document, 0x1C))
        guard to > from, document.startIndex + to <= document.endIndex else { return nil }
        let slice = document.subdata(
            in: (document.startIndex + from) ..< (document.startIndex + to))
        return clean(String(data: slice, encoding: .windowsCP1252) ?? "")
    }

    /// Word sème des caractères de service dans le texte (marques de champ,
    /// puces, cellules de tableau) : ils deviennent des blancs ou des sauts.
    static func clean(_ raw: String) -> String? {
        var output = ""
        output.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x0D, 0x07: output.append("\n\n")   // fin de paragraphe, fin de cellule
            case 0x0B: output.append("\n")           // saut de ligne forcé
            case 0x09: output.append("\t")
            // Marques de champ et d'objet : le texte entre elles est conservé,
            // seuls les codes disparaissent.
            case 0x01, 0x02, 0x05, 0x08, 0x13, 0x14, 0x15, 0x1E, 0x1F: continue
            case 0..<0x20 where scalar.value != 0x0A: continue
            default: output.unicodeScalars.append(scalar)
            }
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Entiers petit-boutistes (OLE2 et Word sont en little-endian)

    static func le16(_ data: Data, _ index: Int) -> UInt16 {
        let base = data.startIndex + index
        guard base >= data.startIndex, base + 1 < data.endIndex else { return 0 }
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    static func le32(_ data: Data, _ index: Int) -> UInt32 {
        let base = data.startIndex + index
        guard base >= data.startIndex, base + 3 < data.endIndex else { return 0 }
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}

/// Un conteneur composé OLE2 (« Compound File Binary »), réduit à ce qu'il faut
/// pour en sortir un flux nommé : l'en-tête, la table d'allocation, l'annuaire.
struct CompoundFile {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let directory: [Entry]
    /// Chaîne du flux miniature (rangé dans l'entrée racine).
    private let miniStream: Data

    struct Entry {
        let name: String
        let type: UInt8
        let firstSector: UInt32
        let size: Int
    }

    /// Marqueurs de fin de chaîne dans la FAT.
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let freeSector: UInt32 = 0xFFFF_FFFF

    init?(data: Data) {
        guard data.count >= 512,
              data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        else { return nil }
        self.data = data

        let shift = Int(LegacyWordDocument.le16(data, 0x1E))
        let miniShift = Int(LegacyWordDocument.le16(data, 0x20))
        guard shift >= 7, shift <= 20, miniShift >= 2, miniShift < shift else { return nil }
        sectorSize = 1 << shift
        miniSectorSize = 1 << miniShift
        miniCutoff = Int(LegacyWordDocument.le32(data, 0x38))

        // DIFAT : les 109 premières entrées sont dans l'en-tête, la suite dans
        // des secteurs chaînés. Les documents Word dépassent rarement 109
        // (≈ 64 Mo), mais on suit la chaîne quand même.
        var fatSectors: [UInt32] = []
        for index in 0 ..< 109 {
            let sector = LegacyWordDocument.le32(data, 0x4C + index * 4)
            if sector == Self.freeSector || sector == Self.endOfChain { break }
            fatSectors.append(sector)
        }
        var difatSector = LegacyWordDocument.le32(data, 0x44)
        var difatGuard = 0
        let perSector = sectorSize / 4
        while difatSector != Self.endOfChain, difatSector != Self.freeSector, difatGuard < 4096 {
            guard let block = Self.rawSector(data, difatSector, sectorSize) else { break }
            for index in 0 ..< (perSector - 1) {
                let sector = LegacyWordDocument.le32(block, index * 4)
                if sector == Self.freeSector || sector == Self.endOfChain { break }
                fatSectors.append(sector)
            }
            difatSector = LegacyWordDocument.le32(block, (perSector - 1) * 4)
            difatGuard += 1
        }

        var table: [UInt32] = []
        table.reserveCapacity(fatSectors.count * perSector)
        for sector in fatSectors {
            guard let block = Self.rawSector(data, sector, sectorSize) else { continue }
            for index in 0 ..< perSector {
                table.append(LegacyWordDocument.le32(block, index * 4))
            }
        }
        guard !table.isEmpty else { return nil }
        fat = table

        // Mini-FAT : la table d'allocation des petits flux.
        var mini: [UInt32] = []
        var miniSector = LegacyWordDocument.le32(data, 0x3C)
        var miniGuard = 0
        while miniSector != Self.endOfChain, miniSector != Self.freeSector,
              miniSector < UInt32(table.count), miniGuard < 65536 {
            guard let block = Self.rawSector(data, miniSector, sectorSize) else { break }
            for index in 0 ..< perSector {
                mini.append(LegacyWordDocument.le32(block, index * 4))
            }
            miniSector = table[Int(miniSector)]
            miniGuard += 1
        }
        miniFAT = mini

        // L'annuaire : une chaîne de secteurs pleins d'entrées de 128 octets.
        var entries: [Entry] = []
        var directorySector = LegacyWordDocument.le32(data, 0x30)
        var directoryGuard = 0
        while directorySector != Self.endOfChain, directorySector != Self.freeSector,
              directorySector < UInt32(table.count), directoryGuard < 65536 {
            guard let block = Self.rawSector(data, directorySector, sectorSize) else { break }
            for slot in 0 ..< (sectorSize / 128) {
                let base = slot * 128
                let nameLength = Int(LegacyWordDocument.le16(block, base + 0x40))
                let type = block.count > base + 0x42 ? block[block.startIndex + base + 0x42] : 0
                var name = ""
                if nameLength > 2, nameLength <= 64, block.count >= base + nameLength {
                    let from = block.startIndex + base
                    // La longueur inclut le zéro terminal UTF-16.
                    let slice = block.subdata(in: from ..< (from + nameLength - 2))
                    name = String(data: slice, encoding: .utf16LittleEndian) ?? ""
                }
                entries.append(Entry(
                    name: name,
                    type: type,
                    firstSector: LegacyWordDocument.le32(block, base + 0x74),
                    size: Int(LegacyWordDocument.le32(block, base + 0x78))
                ))
            }
            directorySector = table[Int(directorySector)]
            directoryGuard += 1
        }
        guard let root = entries.first(where: { $0.type == 5 }) else { return nil }
        directory = entries

        // Le flux miniature vit dans la chaîne de l'entrée racine.
        miniStream = Self.chain(data: data, fat: table, sectorSize: sectorSize,
                                first: root.firstSector, size: root.size)
    }

    /// Le contenu d'un flux nommé (« WordDocument », « 1Table »…).
    func stream(named name: String) -> Data? {
        guard let entry = directory.first(where: { $0.type == 2 && $0.name == name }),
              entry.size > 0 else { return nil }

        if entry.size < miniCutoff {
            return Self.miniChain(miniStream: miniStream, miniFAT: miniFAT,
                                  miniSectorSize: miniSectorSize,
                                  first: entry.firstSector, size: entry.size)
        }
        return Self.chain(data: data, fat: fat, sectorSize: sectorSize,
                          first: entry.firstSector, size: entry.size)
    }

    // MARK: - Parcours des chaînes

    static func rawSector(_ data: Data, _ sector: UInt32, _ sectorSize: Int) -> Data? {
        let start = 512 + Int(sector) * sectorSize
        guard start >= 512, start + sectorSize <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + start) ..< (data.startIndex + start + sectorSize))
    }

    static func chain(data: Data, fat: [UInt32], sectorSize: Int,
                      first: UInt32, size: Int) -> Data {
        var output = Data()
        output.reserveCapacity(min(max(0, size), data.count))
        var sector = first
        var steps = 0
        let limit = size / sectorSize + 2
        var visited = Set<UInt32>()
        while sector != endOfChain, sector != freeSector,
              Int(sector) < fat.count, output.count < size, steps <= limit {
            guard visited.insert(sector).inserted else { break }
            guard let block = rawSector(data, sector, sectorSize) else { break }
            output.append(block)
            sector = fat[Int(sector)]
            steps += 1
        }
        return output.prefix(size)
    }

    static func miniChain(miniStream: Data, miniFAT: [UInt32], miniSectorSize: Int,
                          first: UInt32, size: Int) -> Data {
        var output = Data()
        output.reserveCapacity(min(max(0, size), miniStream.count))
        var sector = first
        var steps = 0
        let limit = size / miniSectorSize + 2
        var visited = Set<UInt32>()
        while sector != endOfChain, sector != freeSector,
              Int(sector) < miniFAT.count, output.count < size, steps <= limit {
            guard visited.insert(sector).inserted else { break }
            let start = miniStream.startIndex + Int(sector) * miniSectorSize
            guard start + miniSectorSize <= miniStream.endIndex else { break }
            output.append(miniStream.subdata(in: start ..< (start + miniSectorSize)))
            sector = miniFAT[Int(sector)]
            steps += 1
        }
        return output.prefix(size)
    }
}
