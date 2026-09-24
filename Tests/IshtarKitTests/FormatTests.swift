import Foundation
import Testing
import ZIPFoundation
@testable import IshtarCatalog
@testable import IshtarIngest

// MARK: - Fabriques

enum FormatFixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Un PalmDB Mobipocket minimal mais complet : en-tête, table des
    /// enregistrements, en-tête PalmDOC + MOBI, EXTH, et un texte non compressé.
    static func makeMOBI(
        at url: URL,
        title: String,
        author: String,
        bodyText: String,
        encryption: Int = 0,
        version: Int = 6
    ) throws {
        func be16(_ value: Int) -> Data { Data([UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        func be32(_ value: Int) -> Data {
            Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                  UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }

        // EXTH : titre (503) et auteur (100).
        func exthRecord(_ type: Int, _ value: String) -> Data {
            let payload = Data(value.utf8)
            return be32(type) + be32(payload.count + 8) + payload
        }
        let exthBody = exthRecord(100, author) + exthRecord(503, title)
        var exth = Data("EXTH".utf8) + be32(exthBody.count + 12) + be32(2) + exthBody
        while exth.count % 4 != 0 { exth.append(0) }

        // Tous les décalages du format MOBI se comptent depuis le DÉBUT du
        // premier enregistrement, en-tête PalmDOC compris — d'où l'écriture
        // par positions absolues plutôt que par concaténation.
        let mobiHeaderLength = 232
        let exthStart = 16 + mobiHeaderLength          // l'EXTH suit l'en-tête MOBI
        let titleBytes = Data(title.utf8)
        let titleOffset = exthStart + exth.count

        var record0 = Data(repeating: 0, count: exthStart)
        func poke(_ offset: Int, _ bytes: Data) {
            record0.replaceSubrange(offset ..< (offset + bytes.count), with: bytes)
        }
        // En-tête PalmDOC (0 → 15).
        poke(0, be16(1))                                // compression : aucune
        poke(4, be32(bodyText.utf8.count))              // longueur du texte
        poke(8, be16(1))                                // nombre d'enregistrements de texte
        poke(10, be16(4096))                            // taille d'un enregistrement
        poke(12, be16(encryption))
        // En-tête MOBI (16 → 247).
        poke(16, Data("MOBI".utf8))
        poke(20, be32(mobiHeaderLength))
        poke(24, be32(2))                               // type : livre
        poke(28, be32(65001))                           // encodage : UTF-8
        poke(32, be32(0x1234))                          // uid
        poke(36, be32(version))
        poke(84, be32(titleOffset))
        poke(88, be32(titleBytes.count))
        poke(128, be32(0x40))                           // drapeau : un EXTH suit
        record0 += exth + titleBytes

        let record1 = Data(bodyText.utf8)

        // En-tête PalmDB : 78 octets, puis 8 octets par enregistrement.
        var header = Data("ISHTARTEST".utf8)
        header.append(Data(repeating: 0, count: 32 - header.count))
        header += Data(repeating: 0, count: 28)          // attributs, dates…
        header += Data("BOOKMOBI".utf8)                  // 60 : type + creator
        header += be32(0) + be32(0)                      // 68 : uid seed, next list
        header += be16(2)                                // 76 : nombre d'enregistrements

        let firstOffset = 78 + 2 * 8 + 2
        var table = Data()
        table += be32(firstOffset) + be32(0)
        table += be32(firstOffset + record0.count) + be32(0x40)
        table += Data([0, 0])                            // remplissage de 2 octets

        try (header + table + record0 + record1).write(to: url)
    }

    /// Un DOCX minimal : `word/document.xml` et `docProps/core.xml`.
    static func makeDOCX(at url: URL, title: String, author: String,
                         paragraphs: [String]) throws {
        let body = paragraphs
            .map { "<w:p><w:r><w:t>\($0)</w:t></w:r></w:p>" }
            .joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>\(body)</w:body>
        </w:document>
        """
        let core = """
        <?xml version="1.0" encoding="UTF-8"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                           xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>\(title)</dc:title>
          <dc:creator>\(author)</dc:creator>
        </cp:coreProperties>
        """
        try writeZIP(at: url, files: [
            ("word/document.xml", document), ("docProps/core.xml", core),
        ])
    }

    /// Un CBZ minimal : rien que des images (des octets PNG plausibles).
    static func makeCBZ(at url: URL, pages: Int) throws {
        let archive = try Archive(url: url, accessMode: .create)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 32))
        for index in 1 ... pages {
            try archive.addEntry(
                with: String(format: "page%03d.png", index), type: .file,
                uncompressedSize: Int64(png.count),
                provider: { position, size in png.subdata(in: Int(position)..<Int(position) + size) })
        }
    }

    static func writeZIP(at url: URL, files: [(String, String)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, content) in files {
            let data = Data(content.utf8)
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                })
        }
    }
}

// MARK: - Vocabulaire des formats

@Suite("Formats — vocabulaire")
struct DocumentFormatTests {
    @Test func extensionsEtVariantes() {
        #expect(DocumentFormat(fileExtension: "MOBI") == .mobi)
        #expect(DocumentFormat(fileExtension: "azw3") == .azw3)
        #expect(DocumentFormat(fileExtension: "htm") == .html)
        #expect(DocumentFormat(fileExtension: "markdown") == .md)
        #expect(DocumentFormat(fileExtension: "prc") == .mobi)
        #expect(DocumentFormat(fileExtension: "xyz") == nil)
    }

    @Test func doubleExtensionFictionBook() {
        #expect(DocumentFormat(fileName: "roman.fb2.zip") == .fbz)
        #expect(DocumentFormat(fileName: "roman.fb2") == .fb2)
        #expect(DocumentFormat(fileName: "Kant, Critique.epub") == .epub)
    }

    @Test func moteursDAffichage() {
        #expect(DocumentFormat.pdf.readingEngine == .pdfKit)
        for format: DocumentFormat in [.epub, .mobi, .azw, .azw3, .fb2, .fbz, .cbz] {
            #expect(format.readingEngine == .foliate, "\(format) devrait passer par foliate")
        }
        for format: DocumentFormat in [.txt, .md, .html, .docx, .doc, .odt, .rtf] {
            #expect(format.readingEngine == .text, "\(format) devrait passer par le lecteur texte")
        }
        // Sans moteur : la raison est TOUJOURS dite, jamais un refus muet.
        for format: DocumentFormat in [.djvu, .cbr, .kfx] {
            #expect(format.readingEngine == .none)
            #expect(format.unreadableReason != nil, "\(format) doit dire pourquoi")
        }
    }

    @Test func toutFormatLisibleEstDecidable() {
        // Invariant de l'aiguillage : un format a un moteur, ou une raison.
        for format in DocumentFormat.allCases {
            #expect(format.readingEngine != .none || format.unreadableReason != nil)
        }
    }
}

// MARK: - Reniflage

@Suite("Formats — reconnaissance par le contenu")
struct FormatDetectorTests {
    @Test func leContenuCorrigeLeNom() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Un EPUB déguisé en PDF : le scan doit voir un EPUB.
        let menteur = directory.appendingPathComponent("faux.pdf")
        try Fixtures.makeEPUB(at: menteur, title: "Titre", author: "Auteur",
                              year: "2020", isbn13: nil, bodyText: "Texte")
        #expect(FormatDetector.resolve(fileURL: menteur) == .epub)
    }

    @Test func leNomTrancheEntreVariantesDUnMemeContenu() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // MOBI et AZW sont le même conteneur : le nom porte la nuance.
        let azw = directory.appendingPathComponent("livre.azw")
        try FormatFixtures.makeMOBI(at: azw, title: "T", author: "A", bodyText: "corps")
        #expect(FormatDetector.resolve(fileURL: azw) == .azw)
    }

    @Test func archivesZipDistinguees() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cbz = directory.appendingPathComponent("bd.cbz")
        try FormatFixtures.makeCBZ(at: cbz, pages: 3)
        #expect(FormatDetector.probe(fileURL: cbz).format == .cbz)

        let docx = directory.appendingPathComponent("memoire.docx")
        try FormatFixtures.makeDOCX(at: docx, title: "T", author: "A", paragraphs: ["un"])
        #expect(FormatDetector.probe(fileURL: docx).format == .docx)
    }

    @Test func verrouEditeurRepere() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let libre = directory.appendingPathComponent("libre.mobi")
        try FormatFixtures.makeMOBI(at: libre, title: "T", author: "A",
                                    bodyText: "corps", encryption: 0)
        #expect(FormatDetector.probe(fileURL: libre).isProtected == false)

        let ferme = directory.appendingPathComponent("achete.azw")
        try FormatFixtures.makeMOBI(at: ferme, title: "T", author: "A",
                                    bodyText: "corps", encryption: 2)
        #expect(FormatDetector.probe(fileURL: ferme).isProtected)
    }

    @Test func texteEtBalisage() {
        #expect(FormatDetector.textFlavour(Data("Un simple paragraphe de texte.".utf8)) == .txt)
        #expect(FormatDetector.textFlavour(Data("<!DOCTYPE html><html><body>x".utf8)) == .html)
        #expect(FormatDetector.textFlavour(Data("<?xml version=\"1.0\"?><FictionBook>".utf8)) == .fb2)
        // Du binaire ne doit jamais passer pour du texte.
        #expect(FormatDetector.textFlavour(Data((0 ..< 200).map { UInt8($0 % 7) })) == nil)
    }

    @Test func fichierVideOuTronque() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vide = directory.appendingPathComponent("vide.epub")
        try Data().write(to: vide)
        #expect(FormatDetector.probe(fileURL: vide).isDamaged)
    }
}

// MARK: - Famille MOBI

@Suite("Formats — MOBI, AZW, AZW3")
struct MOBITests {
    @Test func texteEtMetadonnees() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("livre.mobi")
        try FormatFixtures.makeMOBI(
            at: url, title: "L'art de la guerre", author: "Sun Tzu",
            bodyText: "<html><body><p>Toute guerre est fondée sur la tromperie.</p></body></html>")

        let document = try MOBIDocument(fileURL: url)
        #expect(document.plainText.contains("Toute guerre est fondée sur la tromperie."))
        #expect(document.metadata.title == "L'art de la guerre")
        #expect(document.metadata.author == "Sun Tzu")
    }

    @Test func fichierChiffreRefuse() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("achete.azw")
        try FormatFixtures.makeMOBI(at: url, title: "T", author: "A",
                                    bodyText: "corps", encryption: 2)
        #expect(throws: MOBIDocument.MOBIError.protected) {
            _ = try MOBIDocument(fileURL: url)
        }
        // Et l'extraction ne rend rien plutôt que du bruit.
        #expect(TextExtractor.extract(fileURL: url, format: .azw) == nil)
    }

    @Test func decompressionPalmDOC() {
        // Littéraux simples.
        #expect(MOBIDocument.decompressPalmDOC(Data([0x41, 0x42, 0x43])) == Data("ABC".utf8))
        // « espace + lettre » : l'octet 0xE1 vaut « espace » puis 0x61 ('a').
        #expect(MOBIDocument.decompressPalmDOC(Data([0xE1])) == Data(" a".utf8))
        // Paire longueur/distance : « abcd » puis 3 octets recopiés à 4 en arrière.
        let source = Data([UInt8(0x61), UInt8(0x62), UInt8(0x63), UInt8(0x64), UInt8(0x80), UInt8(4 << 3)])
        #expect(MOBIDocument.decompressPalmDOC(source) == Data("abcdabc".utf8))
    }

    @Test func entonnoirLitLesMetadonneesEmbarquees() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("hegel.azw3")
        try FormatFixtures.makeMOBI(at: url, title: "The Future of Hegel",
                                    author: "Malabou, Catherine", bodyText: "corps")
        let guess = try #require(EmbeddedMetadata.read(fileURL: url, format: .azw3))
        #expect(guess.title == "The Future of Hegel")
        #expect(guess.author == "Malabou, Catherine")
        #expect(guess.confidence == .structured)
    }
}

// MARK: - Bureautique et balisage

@Suite("Formats — DOCX, RTF, HTML")
struct OfficeDocumentTests {
    @Test func docxTexteEtFiche() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("memoire.docx")
        try FormatFixtures.makeDOCX(
            at: url, title: "L'efficience du sensible", author: "Aubin Robert",
            paragraphs: ["Premier paragraphe.", "Second paragraphe."])

        let text = try #require(OfficeDocument.docxText(url))
        #expect(text.contains("Premier paragraphe."))
        #expect(text.contains("Second paragraphe."))

        let guess = try #require(EmbeddedMetadata.read(fileURL: url, format: .docx))
        #expect(guess.title == "L'efficience du sensible")
        #expect(guess.author == "Aubin Robert")
    }

    @Test func rtfRenduEnTexte() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("note.rtf")
        let rtf = #"""
        {\rtf1\ansi\ansicpg1252\deff0
        {\fonttbl{\f0\froman Times;}}
        {\info{\title Ne pas indexer}}
        \f0\fs24 Le concept de \b diff\'e9rance \b0 chez Derrida.\par
        Second paragraphe.\par}
        """#
        try Data(rtf.utf8).write(to: url)

        let text = try #require(OfficeDocument.rtfText(url))
        #expect(text.contains("différance"))
        #expect(text.contains("Second paragraphe."))
        // Les groupes de service ne doivent pas fuir dans le texte.
        #expect(!text.contains("Times"))
        #expect(!text.contains("Ne pas indexer"))
    }

    @Test func htmlDepouilleDeSesBalises() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("article.htm")
        let html = """
        <!DOCTYPE html><html><head><title>x</title>
        <style>body { color: red }</style><script>var x = 1</script></head>
        <body><h1>Putnam on Synonymity</h1><p>Par Wilfrid Sellars.</p></body></html>
        """
        try Data(html.utf8).write(to: url)

        let text = try #require(OfficeDocument.htmlText(url))
        #expect(text.contains("Putnam on Synonymity"))
        #expect(text.contains("Par Wilfrid Sellars."))
        #expect(!text.contains("color: red"))
        #expect(!text.contains("var x"))
    }
}

// MARK: - Le pipeline dans son ensemble

@Suite("Formats — extraction")
struct ExtractionScopeTests {
    @Test func lesFormatsSansCoucheTexteNeRendentRien() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cbz = directory.appendingPathComponent("bd.cbz")
        try FormatFixtures.makeCBZ(at: cbz, pages: 2)
        #expect(TextExtractor.extract(fileURL: cbz, format: .cbz) == nil)
        #expect(DocumentFormat.cbz.isTextExtractable == false)
    }

    @Test func leMobiEstIndexe() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("livre.mobi")
        try FormatFixtures.makeMOBI(
            at: url, title: "T", author: "A",
            bodyText: "<html><body><p>" + String(repeating: "Phrase de test. ", count: 600)
                + "</p></body></html>")

        let extracted = try #require(TextExtractor.extract(fileURL: url, format: .mobi))
        #expect(extracted.pages.count > 1, "un long texte doit être paginé")
        #expect(extracted.needsOCR == false)
        #expect(extracted.pages.allSatisfy { !$0.content.isEmpty })
        // Numérotation continue à partir de 1.
        #expect(extracted.pages.map(\.number) == Array(1 ... extracted.pages.count))
    }

    @Test func leScanReconnaitLesNouveauxFormats() throws {
        let directory = try FormatFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FormatFixtures.makeMOBI(at: directory.appendingPathComponent("a.mobi"),
                                    title: "T", author: "A", bodyText: "corps")
        try FormatFixtures.makeDOCX(at: directory.appendingPathComponent("b.docx"),
                                    title: "T", author: "A", paragraphs: ["x"])
        try FormatFixtures.makeCBZ(at: directory.appendingPathComponent("c.cbz"), pages: 1)
        try Data("note".utf8).write(to: directory.appendingPathComponent("d.txt"))

        let report = LibraryScanner(computeHashes: false).scan(directory: directory)
        let formats = Set(report.files.map(\.format))
        #expect(formats == [.mobi, .docx, .cbz, .txt])
        #expect(report.unsupportedCount == 0)
    }
}
