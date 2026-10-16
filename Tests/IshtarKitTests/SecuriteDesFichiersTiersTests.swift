import Foundation
import Testing
import ZIPFoundation
@testable import IshtarCatalog
@testable import IshtarIngest
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Les fichiers confiés par des tiers (l'atelier des fonds du serveur les lit
/// dans un conteneur) ne doivent rien faire lire à la machine : ni par une
/// entité XML externe (XXE), ni par une image que ImageMagick interpréterait.
/// Un test par chemin de lecture XML, et un pour les images.

/// Un fichier-témoin que le XML piégé tente de lire : si sa marque reparaît
/// dans un texte ou une fiche, l'entité externe a été suivie.
private struct Temoin {
    let dossier: URL
    let marque: String

    init(contenu: String? = nil) throws {
        dossier = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-temoin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        marque = contenu ?? "TEMOIN-\(UUID().uuidString)"
        try Data(marque.utf8).write(to: fichier)
    }

    var fichier: URL { dossier.appendingPathComponent("temoin.txt") }
    func effacer() { try? FileManager.default.removeItem(at: dossier) }

    /// Le DOCTYPE qui déclare l'entité `&xxe;` sur le fichier-témoin.
    func doctype(_ racine: String) -> String {
        "<!DOCTYPE \(racine) [<!ENTITY xxe SYSTEM \"\(fichier.absoluteString)\">]>"
    }
}

private let conteneurEPUB = """
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""

@Suite("Sécurité — XML piégé (entités externes)")
struct XMLPiegeTests {
    private func dossier() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-xxe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Le texte d'un EPUB ne suit pas l'entité externe d'un chapitre")
    func extractionEPUB() throws {
        let temoin = try Temoin(); defer { temoin.effacer() }
        let dir = try dossier(); defer { try? FileManager.default.removeItem(at: dir) }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """
        let chapitre = """
        <?xml version="1.0" encoding="UTF-8"?>
        \(temoin.doctype("html"))
        <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Texte ordinaire du chapitre.</p><p>&xxe;</p></body></html>
        """
        let url = dir.appendingPathComponent("piege.epub")
        try FormatFixtures.writeZIP(at: url, files: [
            ("META-INF/container.xml", conteneurEPUB), ("OEBPS/content.opf", opf), ("OEBPS/c1.xhtml", chapitre),
        ])
        let texte = try #require(TextExtractor.extractEPUB(url))
        let tout = texte.pages.map(\.content).joined(separator: "\n")
        #expect(tout.contains("Texte ordinaire du chapitre."))
        #expect(!tout.contains(temoin.marque))
    }

    @Test("Les métadonnées d'un EPUB ne suivent pas l'entité externe de l'OPF")
    func metadonneesEPUB() throws {
        let temoin = try Temoin(); defer { temoin.effacer() }
        let dir = try dossier(); defer { try? FileManager.default.removeItem(at: dir) }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        \(temoin.doctype("package"))
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>&xxe;</dc:title><dc:creator>Auteur Fictif</dc:creator><dc:publisher>&xxe;</dc:publisher>
          </metadata>
          <manifest/><spine/>
        </package>
        """
        let url = dir.appendingPathComponent("piege.epub")
        try FormatFixtures.writeZIP(at: url, files: [("META-INF/container.xml", conteneurEPUB), ("OEBPS/content.opf", opf)])
        let fiche = try #require(EmbeddedMetadata.read(fileURL: url, format: .epub))
        #expect(fiche.author == "Auteur Fictif")
        #expect(!fiche.title.contains(temoin.marque))
        #expect(fiche.publisher?.contains(temoin.marque) != true)
    }

    @Test("La fiche Calibre (metadata.opf) ne suit pas l'entité externe")
    func ficheCalibre() throws {
        let temoin = try Temoin(); defer { temoin.effacer() }
        let dir = try dossier(); defer { try? FileManager.default.removeItem(at: dir) }
        let livre = dir.appendingPathComponent("Un livre (1).epub")
        try Data("pas un vrai livre".utf8).write(to: livre)
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        \(temoin.doctype("package"))
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>&xxe;</dc:title><dc:creator>Auteur Fictif</dc:creator><dc:publisher>&xxe;</dc:publisher>
          </metadata>
        </package>
        """
        try Data(opf.utf8).write(to: dir.appendingPathComponent("metadata.opf"))
        let fiche = try #require(EmbeddedMetadata.readCalibreSidecar(for: livre))
        #expect(fiche.author == "Auteur Fictif")
        #expect(!fiche.title.contains(temoin.marque))
        #expect(fiche.publisher?.contains(temoin.marque) != true)
    }

    @Test("DOCX, ODT et FB2 ne suivent pas l'entité externe")
    func formatsBureautiques() throws {
        let temoin = try Temoin(); defer { temoin.effacer() }
        let dir = try dossier(); defer { try? FileManager.default.removeItem(at: dir) }

        let docx = dir.appendingPathComponent("piege.docx")
        try FormatFixtures.writeZIP(at: docx, files: [
            ("word/document.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            \(temoin.doctype("w:document"))
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>&xxe;</w:t></w:r></w:p><w:p><w:r><w:t>Paragraphe ordinaire.</w:t></w:r></w:p></w:body></w:document>
            """),
            ("docProps/core.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            \(temoin.doctype("cp:coreProperties"))
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>&xxe;</dc:title><dc:creator>Auteur Fictif</dc:creator></cp:coreProperties>
            """),
        ])
        let texteDocx = OfficeDocument.docxText(docx) ?? ""
        #expect(texteDocx.contains("Paragraphe ordinaire."))
        #expect(!texteDocx.contains(temoin.marque))
        let ficheDocx = OfficeDocument.docxMetadata(docx)
        #expect(ficheDocx?.author == "Auteur Fictif")
        #expect(ficheDocx?.title?.contains(temoin.marque) != true)

        let odt = dir.appendingPathComponent("piege.odt")
        try FormatFixtures.writeZIP(at: odt, files: [
            ("mimetype", "application/vnd.oasis.opendocument.text"),
            ("content.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            \(temoin.doctype("office:document-content"))
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>&xxe;</text:p><text:p>Paragraphe ordinaire.</text:p></office:text></office:body></office:document-content>
            """),
        ])
        let texteOdt = OfficeDocument.odtText(odt) ?? ""
        #expect(texteOdt.contains("Paragraphe ordinaire."))
        #expect(!texteOdt.contains(temoin.marque))

        let fb2 = dir.appendingPathComponent("piege.fb2")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        \(temoin.doctype("FictionBook"))
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><book-title>&xxe;</book-title><author><first-name>Auteur</first-name><last-name>Fictif</last-name></author></title-info></description><body><section><p>&xxe;</p><p>Paragraphe ordinaire.</p></section></body></FictionBook>
        """.utf8).write(to: fb2)
        let texteFb2 = OfficeDocument.fictionBookText(fb2, zipped: false) ?? ""
        #expect(texteFb2.contains("Paragraphe ordinaire."))
        #expect(!texteFb2.contains(temoin.marque))
        let ficheFb2 = OfficeDocument.fictionBookMetadata(fb2, zipped: false)
        #expect(ficheFb2?.author == "Auteur Fictif")
        #expect(ficheFb2?.title?.contains(temoin.marque) != true)
    }

    #if !canImport(QuickLookThumbnailing)
    /// Le chemin des couvertures d'EPUB (Linux). Seuls des attributs en sortent,
    /// où une entité externe est interdite : le piège est donc un fragment de
    /// XML que l'entité externe ferait entrer dans le manifeste (une entité
    /// externe s'analyse comme du XML). Si elle est suivie, le manifeste désigne
    /// l'image du ZIP et la couverture sort.
    @Test("La couverture d'un EPUB ne suit pas l'entité externe de l'OPF")
    func couvertureEPUB() throws {
        let temoin = try Temoin(contenu: #"<item id="c" href="couverture-piegee.png" media-type="image/png" properties="cover-image"/>"#)
        defer { temoin.effacer() }
        let dir = try dossier(); defer { try? FileManager.default.removeItem(at: dir) }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        \(temoin.doctype("package"))
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest>&xxe;</manifest></package>
        """
        let url = dir.appendingPathComponent("piege.epub")
        try FormatFixtures.writeZIP(at: url, files: [
            ("META-INF/container.xml", conteneurEPUB), ("OEBPS/content.opf", opf),
            ("OEBPS/couverture-piegee.png", "contenu de l'image"),
        ])
        #expect(CoverRenderer.epubCover(url) == nil)
    }

    @Test("Un EPUB ordinaire garde sa couverture")
    func couvertureOrdinaire() throws {
        let dir = try dossier(); defer { try? FileManager.default.removeItem(at: dir) }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest><item id="c" href="couverture.png" media-type="image/png" properties="cover-image"/></manifest>
        </package>
        """
        let url = dir.appendingPathComponent("ordinaire.epub")
        try FormatFixtures.writeZIP(at: url, files: [
            ("META-INF/container.xml", conteneurEPUB), ("OEBPS/content.opf", opf), ("OEBPS/couverture.png", "contenu de l'image"),
        ])
        #expect(CoverRenderer.epubCover(url).map { String(decoding: $0, as: UTF8.self) } == "contenu de l'image")
    }
    #endif

    @Test("Règle : le XML ne se lit que par SafeXML, ImageMagick que par MachineTools")
    func regleDesSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let fichiers = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        // Ce qui analyse du XML (les entités externes y sont suivies par défaut), ce qui les rouvrirait, et le lancement direct d'ImageMagick.
        let interdits = [
            "XMLDocument(", "XMLElement(xmlString", "XMLDTD(", "externalEntityResolvingPolicy", "allowedExternalEntityURLs",
            "run(\"convert\"", "run(\"magick\"", "\"/usr/bin/convert\"",
        ]
        var vus = 0
        for case let fichier as URL in fichiers where fichier.pathExtension == "swift" {
            vus += 1
            let nom = fichier.lastPathComponent
            let texte = try String(contentsOf: fichier, encoding: .utf8)
            for (numero, ligne) in texte.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = String(ligne).components(separatedBy: "//").first ?? ""
                for motif in interdits where code.contains(motif) {
                    let permis = (nom == "SafeXML.swift" && motif == "XMLDocument(")
                        || (nom == "MachineTools.swift" && motif.hasPrefix("run(\""))
                    if !permis { Issue.record("\(nom):\(numero + 1) : « \(motif) » est interdit hors de SafeXML.swift / MachineTools.swift") }
                }
                if code.contains("XMLParser(") && !texte.contains("shouldResolveExternalEntities = false") {
                    Issue.record("\(nom):\(numero + 1) : XMLParser sans shouldResolveExternalEntities = false")
                }
            }
        }
        #expect(vus > 10, "les sources n'ont pas été trouvées")
    }
}

#if os(Linux)
@Suite("Sécurité — images piégées (ImageMagick)")
struct ImagesPiegeesTests {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    static let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
    static let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAACAAIDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAAAAAHCf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/ADoDFU3/2Q==")!
    static let webp = Data(base64Encoded: "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAIAAgA0JaACdLoB+AADsAD+8MQL/yC5YXXI1/8gP+QH/ID/+PIAAAA=")!

    /// Un BMP de 1 × 1 pixel : lisible par ImageMagick (qui le reconnaît à sa signature), mais pas une couverture permise.
    static var bmp: Data {
        func le32(_ v: Int) -> [UInt8] { (0 ..< 4).map { UInt8(v >> ($0 * 8) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0 ..< 2).map { UInt8(v >> ($0 * 8) & 0xFF) } }
        let entete: [UInt8] = Array("BM".utf8) + le32(58) + le32(0) + le32(54)
        let image: [UInt8] = le32(40) + le32(1) + le32(1) + le16(1) + le16(24) + le32(0) + le32(4) + le32(0) + le32(0) + le32(0) + le32(0)
        return Data(entete + image + [0, 0, 255, 0])
    }

    static let dessin = Data("push graphic-context\nviewbox 0 0 10 10\nfill red\nrectangle 0,0 5,5\npop graphic-context\n".utf8)

    private func ecrire(_ data: Data, dans dir: URL, nom: String) throws -> URL {
        let url = dir.appendingPathComponent(nom)
        try data.write(to: url)
        return url
    }

    @Test("Les couvertures ordinaires (PNG, JPEG, GIF, WebP) passent")
    func ordinaires() {
        for (nom, image) in [("png", Self.png), ("jpeg", Self.jpeg), ("gif", Self.gif), ("webp", Self.webp)] {
            #expect(CoverRenderer.thumbnail(of: image).map { !$0.isEmpty } == true, "\(nom)")
        }
    }

    @Test("Un fichier qui n'est pas une image permise n'est jamais confié à ImageMagick")
    func refusesParLaSignature() {
        #expect(CoverRenderer.thumbnail(of: Self.bmp) == nil)
        #expect(CoverRenderer.thumbnail(of: Self.dessin) == nil)
        #expect(CoverRenderer.thumbnail(of: Data("%PDF-1.4\n".utf8)) == nil)
        #expect(CoverRenderer.thumbnail(of: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)) == nil)
        #expect(CoverRenderer.thumbnail(of: Data()) == nil)
    }

    @Test("La signature décide du format, jamais le nom ni le contenu au-delà")
    func signatures() {
        #expect(MachineTools.imageCoder(for: Self.png) == "png")
        #expect(MachineTools.imageCoder(for: Self.gif) == "gif")
        #expect(MachineTools.imageCoder(for: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])) == "jpeg")
        #expect(MachineTools.imageCoder(for: Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBPVP8 ".utf8)) == "webp")
        #expect(MachineTools.imageCoder(for: Self.bmp) == nil)
        #expect(MachineTools.imageCoder(for: Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVEfmt ".utf8)) == nil)
    }

    @Test("La politique d'ImageMagick : formats permis seulement, ni @fichier ni URL")
    func politique() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-magick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try ecrire(Self.png, dans: dir, nom: "ok.png")
        let bmp = try ecrire(Self.bmp, dans: dir, nom: "piege.bmp")
        let mvg = try ecrire(Self.dessin, dans: dir, nom: "piege.mvg")
        let temoin = try ecrire(Data("TEMOIN-\(UUID().uuidString)".utf8), dans: dir, nom: "temoin.txt")

        func sortie(_ entree: String) -> Data? { MachineTools.runImageMagick([entree, "-thumbnail", "10x10", "png:-"]) }
        // Le témoin : une image permise passe.
        #expect(sortie("png:" + png.path) != nil)
        // Un format lisible mais non permis, même désigné explicitement.
        #expect(sortie("bmp:" + bmp.path) == nil)
        #expect(sortie("tiff:" + png.path) == nil)
        #expect(sortie("mvg:" + mvg.path) == nil)
        // Lire un fichier : le texte d'un fichier, une image « inline », un fichier éphémère.
        #expect(sortie("text:" + temoin.path) == nil)
        #expect(sortie("inline:data:image/png;base64," + Self.png.base64EncodedString()) == nil)
        #expect(sortie("ephemeral:" + png.path) == nil)
        // Déjà refusés par la politique du système d'Ubuntu (chemins « @ », délégués URL), et gardés ici
        // pour le jour où elle changerait : une liste « @fichier » et des URL.
        #expect(sortie("label:@" + temoin.path) == nil)
        #expect(sortie("@" + temoin.path) == nil)
        #expect(sortie("https://127.0.0.1:9/couverture.png") == nil)
        #expect(sortie("http://127.0.0.1:9/couverture.png") == nil)
        #expect(sortie("url:http://127.0.0.1:9/couverture.png") == nil)
        // Sans préfixe, c'est la signature du fichier qui décide : un BMP reste refusé.
        #expect(sortie(bmp.path) == nil)
    }
}
#endif
