import Foundation
import Testing
@testable import IshtarCatalog
@testable import IshtarIngest
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// WP-34 — ce que l'outil `ishtar` du serveur (Linux) emploie à la place des
/// cadres d'Apple. Ces tests tournent sur les deux systèmes : sur macOS, ils
/// vérifient les pièces portables contre les originaux.
@Suite("Portage Linux (WP-34)")
struct LinuxPortageTests {

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    @Test("L'empreinte portable rend les vecteurs du NIST")
    func sha256Vectors() {
        #expect(hex(PortableSHA256.hash(data: Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(PortableSHA256.hash(data: Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(PortableSHA256.hash(data: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Un million de « a », en morceaux de tailles inégales.
        var hasher = PortableSHA256()
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 1000)
        for i in 0 ..< 1000 { hasher.update(data: i % 3 == 0 ? chunk.prefix(7) + chunk.dropFirst(7) : chunk) }
        #expect(hex(hasher.finalize()) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    #if canImport(CryptoKit)
    @Test("Sur macOS, l'empreinte portable égale CryptoKit, quelle que soit la découpe")
    func sha256MatchesCryptoKit() {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 55, 56, 63, 64, 65, 127, 128, 1000, 100_003] {
            let data = Data((0 ..< length).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
            var portable = PortableSHA256()
            var offset = 0
            while offset < data.count {
                let size = Int.random(in: 1 ... 97, using: &generator)
                portable.update(data: data.subdata(in: offset ..< min(data.count, offset + size)))
                offset += size
            }
            #expect(portable.finalize() == Array(SHA256.hash(data: data)), "longueur \(length)")
        }
    }
    #endif

    @Test("La sortie de pdfinfo se lit champ par champ")
    func pdfinfoFields() {
        let sortie = """
        Title:          Minima moralia : réflexions sur la vie mutilée
        Author:         Theodor W. Adorno
        Producer:       pdfTeX-1.40
        Pages:          287
        Encrypted:      no
        Page size:      595 x 842 pts (A4)
        """
        let champs = PDFSource.infoFields(sortie)
        #expect(champs["Title"] == "Minima moralia : réflexions sur la vie mutilée")
        #expect(champs["Author"] == "Theodor W. Adorno")
        #expect(champs["Pages"] == "287")
        #expect(champs["Page size"] == "595 x 842 pts (A4)")
    }

    @Test("La sortie de pdftotext se découpe en pages")
    func pdftotextPages() {
        #expect(PDFSource.pagesFromPdftotext("une\u{0C}deux\u{0C}\u{0C}quatre\u{0C}") == ["une", "deux", "", "quatre"])
        #expect(PDFSource.pagesFromPdftotext("") == [])
    }

    @Test("La langue par les mots-outils : sûre, ou rien")
    func languageByFunctionWords() {
        let phraseFR = "Il est dans la maison et elle pense que les mots sont des choses qui ne sont pas pour nous. "
        let phraseLA = "Sed quod est in nobis non est ad hoc ut enim sunt quae esse. "
        #expect(LanguagePass.recognizeByFunctionWords(String(repeating: phraseFR, count: 6))?.code == "fr")
        let anglais = String(repeating: "The question is that it was not for them to say what they are and which of the things are to be done. ", count: 6)
        #expect(LanguagePass.recognizeByFunctionWords(anglais)?.code == "en")
        let espagnol = String(repeating: "El problema de los hombres es que no saben para qué sirve la vida y por eso buscan en los libros lo que ya tienen. ", count: 6)
        #expect(LanguagePass.recognizeByFunctionWords(espagnol)?.code == "es")
        #expect(LanguagePass.recognizeByFunctionWords("Trop court pour juger.") == nil)
        // Une édition bilingue, français et latin à parts égales : on s'abstient.
        #expect(LanguagePass.recognizeByFunctionWords(String(repeating: phraseFR + phraseLA, count: 3)) == nil)
    }

    @Test("La mesure d'une page sur des pixels bruts : blanc, aplat, couverture")
    func coverStatisticsOnRawPixels() throws {
        let blanc = [UInt8](repeating: 255, count: 64 * 64 * 3)
        let mesureBlanc = try #require(CoverInspector.statistics(pixels: blanc, bytesPerPixel: 3))
        #expect(mesureBlanc.inkCoverage == 0)
        #expect(CoverInspector.judge(mesureBlanc, strictness: 0.5) == .nearBlank)

        let bleu: [UInt8] = (0 ..< 64 * 64).flatMap { _ -> [UInt8] in [20, 40, 160] }
        let mesureBleu = try #require(CoverInspector.statistics(pixels: bleu, bytesPerPixel: 3))
        #expect(CoverInspector.judge(mesureBleu, strictness: 0.5) == .uniformField)

        // Les mêmes pixels en RVBA donnent la même mesure qu'en RVB.
        let rvba: [UInt8] = (0 ..< 64 * 64).flatMap { _ -> [UInt8] in [20, 40, 160, 255] }
        #expect(CoverInspector.statistics(pixels: rvba, bytesPerPixel: 4) == mesureBleu)
        #expect(CoverInspector.statistics(pixels: [], bytesPerPixel: 3) == nil)
    }

    @Test("Un attribut sans préfixe se lit sous un espace de noms par défaut (OPF)")
    func plainAttributeUnderDefaultNamespace() throws {
        let opf = try XMLDocument(data: Data(#"<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="c1" href="ch%201.xhtml" w:x="y" xmlns:w="urn:w"/></manifest></package>"#.utf8))
        let item = try #require(try opf.nodes(forXPath: "//*[local-name()='item']").first as? XMLElement)
        #expect(item.plainAttribute("id") == "c1")
        #expect(item.plainAttribute("href") == "ch%201.xhtml")
        #expect(item.plainAttribute("absent") == nil)
    }

    #if !canImport(PDFKit)
    /// Un petit PDF écrit à la main (deux pages de texte, Info : titre et
    /// auteur), avec une table des renvois juste — de quoi éprouver, sous Linux,
    /// toute la voie poppler sans dépendre d'un fichier extérieur.
    static func pdfDEssai() -> Data {
        let page1 = String(repeating: "Bonjour le monde, ceci est une page de texte. ", count: 3)
        let page2 = "ISBN 978-2-07-036002-4. " + String(repeating: "Une seconde page pour la recherche. ", count: 3)
        func flux(_ texte: String) -> String {
            let contenu = "BT /F1 9 Tf 40 760 Td (\(texte)) Tj ET"
            return "<< /Length \(contenu.utf8.count) >>\nstream\n\(contenu)\nendstream"
        }
        let objets = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            flux(page1),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            flux(page2),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Title (Minima moralia) /Author (Theodor W. Adorno) >>",
        ]
        var pdf = "%PDF-1.4\n"
        var positions: [Int] = []
        for (i, objet) in objets.enumerated() {
            positions.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(objet)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objets.count + 1)\n0000000000 65535 f \n"
        for position in positions { pdf += String(format: "%010d 00000 n \n", position) }
        pdf += "trailer\n<< /Size \(objets.count + 1) /Root 1 0 R /Info 8 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    @Test("Sous Linux, un PDF se lit par poppler : pages, texte, Info, ISBN, couverture")
    func popplerReadsAPDF() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-wp34-\(UUID().uuidString).pdf")
        try Self.pdfDEssai().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try #require(PDFSource.open(url))
        #expect(source.pageCount == 2)
        #expect(source.title == "Minima moralia")
        #expect(source.author == "Theodor W. Adorno")
        #expect(source.text(0)?.contains("Bonjour le monde") == true)
        #expect(source.text(1)?.contains("seconde page") == true)
        #expect(source.text(2) == nil)

        let texte = try #require(TextExtractor.extract(fileURL: url, format: .pdf))
        #expect(texte.needsOCR == false)
        #expect(texte.pages.map(\.number) == [1, 2])

        let meta = try #require(EmbeddedMetadata.read(fileURL: url, format: .pdf))
        #expect(meta.title == "Minima moralia")
        #expect(meta.author == "Theodor W. Adorno")
        #expect(meta.isbn13 == "9782070360024")

        let png = try #require(await CoverRenderer.png(for: url))
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        // La page 1 n'a qu'une ligne de texte : à l'exigence maximale, elle est refusée.
        #expect(await CoverRenderer.png(for: url, strictness: 1.0) == nil)
    }
    #endif

    #if !canImport(QuickLookThumbnailing)
    @Test("Une image PPM (P6) se lit, commentaires compris")
    func ppmPixels() {
        var ppm = Data("P6\n# poppler\n2 1\n255\n".utf8)
        ppm.append(contentsOf: [255, 0, 0, 0, 0, 255])
        #expect(CoverRenderer.rgbPixels(ppm: ppm) == [255, 0, 0, 0, 0, 255])
        #expect(CoverRenderer.rgbPixels(ppm: Data("P3\n1 1\n255\n0 0 0".utf8)) == nil)
    }
    #endif
}
