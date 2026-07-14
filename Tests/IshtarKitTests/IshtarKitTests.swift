import Foundation
import PDFKit
import Testing
import ZIPFoundation
@testable import IshtarCatalog
@testable import IshtarIngest
@testable import IshtarSearch

// MARK: - Fabriques de documents de test

enum Fixtures {
    /// Un PDF avec des métadonnées Info et un ISBN dans le texte de la première page.
    static func makePDF(at url: URL, title: String?, author: String?, pageText: String? = nil) {
        let document = PDFDocument()
        var attributes: [AnyHashable: Any] = [:]
        if let title { attributes[PDFDocumentAttribute.titleAttribute] = title }
        if let author { attributes[PDFDocumentAttribute.authorAttribute] = author }
        document.documentAttributes = attributes

        let page = PDFPage()
        document.insert(page, at: 0)
        document.write(to: url)

        // PDFPage() vierge ne porte pas de texte ; si un texte de page est demandé,
        // on l'ajoute en annotation texte libre (extractible par page.string ? non —
        // les tests qui ont besoin de texte de page utilisent un contenu dessiné).
        _ = pageText
    }

    /// Un EPUB minimal : container.xml + OPF Dublin Core.
    static func makeEPUB(at url: URL, title: String, author: String, year: String, isbn13: String?) throws {
        let archive = try Archive(url: url, accessMode: .create)

        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let identifier = isbn13.map { "<dc:identifier>urn:isbn:\($0)</dc:identifier>" } ?? ""
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
            <dc:date>\(year)-01-01</dc:date>
            <dc:language>fr</dc:language>
            <dc:publisher>Éditions de test</dc:publisher>
            \(identifier)
          </metadata>
        </package>
        """

        for (path, content) in [("META-INF/container.xml", container), ("OEBPS/content.opf", opf)] {
            let data = Data(content.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }
    }
}

// MARK: - FilenameParser

@Suite("Entonnoir — étage nom de fichier")
struct FilenameParserTests {
    @Test("Convention Auteur_Année_Titre")
    func authorYearTitle() {
        let guess = FilenameParser.parse(fileName: "Kant_1781_Critique-de-la-raison-pure.pdf")
        #expect(guess.confidence == .structured)
        #expect(guess.author == "Kant")
        #expect(guess.year == "1781")
        #expect(guess.title == "Critique de la raison pure")
    }

    @Test("Convention Anna's Archive avec isbn13 et année")
    func annasArchive() {
        let name = "L' établi -- Robert Linhardt -- Double, Nouvelle édition, Paris, 2011 -- Les Éditions de Minuit -- isbn13 9782707302144 -- 6518c6632001dbe02d1d8574532366bd -- Anna's Archive.epub"
        let guess = FilenameParser.parse(fileName: name)
        #expect(guess.confidence == .structured)
        #expect(guess.title == "L' établi")
        #expect(guess.author == "Robert Linhardt")
        #expect(guess.year == "2011")
        #expect(guess.isbn13 == "9782707302144")
    }

    @Test("Sans-date ND et suffixe de copie (conventions de la Bibliothèque céleste)")
    func noDateAndCopySuffix() {
        let sellars = FilenameParser.parse(fileName: "Sellars_ND_Kant-s-Transcendental-Idealism.txt")
        #expect(sellars.confidence == .structured)
        #expect(sellars.author == "Sellars")
        #expect(sellars.year == nil)
        #expect(sellars.title == "Kant s Transcendental Idealism")

        let celan = FilenameParser.parse(fileName: "Celan_1959_Grille-de-parole_1.azw3")
        #expect(celan.confidence == .structured)
        #expect(celan.year == "1959")
        #expect(celan.title == "Grille de parole")
    }

    @Test("Nom chaotique → repli honnête, à faire vérifier")
    func fallback() {
        let guess = FilenameParser.parse(fileName: "scan_final_VERSION2.pdf")
        #expect(guess.confidence == .fallback)
        #expect(guess.author == nil)
        #expect(!guess.title.isEmpty)
    }
}

// MARK: - Catalogue

@Suite("Catalogue — schéma et ontologie")
struct CatalogTests {
    @Test("Le schéma v1 migre et accepte Œuvre/Édition/Document")
    func schemaRoundTrip() async throws {
        let db = try CatalogDatabase(inMemory: ())

        let work = Work(title: "Critique de la raison pure", curationStatus: .recognized, confidence: .probable)
        let edition = Edition(workId: work.id, publisher: "PUF", year: "1944", language: "fr")
        let document = Document(
            editionId: edition.id,
            filePath: "/tmp/kant.pdf",
            originalFileName: "kant.pdf",
            fileSize: 1234,
            contentHash: "abc",
            format: .pdf
        )

        try await db.pool.write { conn in
            try work.insert(conn)
            try edition.insert(conn)
            try document.insert(conn)
        }

        let fetched = try await db.pool.read { conn in
            try Document.fetchOne(conn, key: document.id)
        }
        #expect(fetched?.originalFileName == "kant.pdf")
        #expect(fetched?.editionId == edition.id)
    }
}

// MARK: - Ingestion de bout en bout

@Suite("Ingestion — scan et entonnoir mécanique")
struct IngestTests {
    /// Crée un dossier temporaire imitant un vrai dossier chaotique :
    /// un fichier bien nommé, un chaotique, un doublon de contenu, un non géré,
    /// et un sous-dossier (qui doit devenir une collection).
    func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-fixture-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("Philosophie allemande")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let content = Data("contenu de test".utf8)
        try content.write(to: root.appendingPathComponent("Kant_1781_Critique.pdf"))
        try Data("autre contenu".utf8).write(to: root.appendingPathComponent("scan sans nom.pdf"))
        try content.write(to: sub.appendingPathComponent("copie de kant.pdf"))
        try Data("pas un livre".utf8).write(to: root.appendingPathComponent("notes.xlsx"))
        return root
    }

    @Test("Le scan voit tout, ne modifie rien, détecte les doublons de contenu")
    func scan() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let report = LibraryScanner().scan(directory: root)
        let after = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

        #expect(before == after, "Invariant : le scan ne modifie jamais le dossier source")
        #expect(report.files.count == 3)
        #expect(report.unsupportedCount == 1)
        #expect(report.duplicateGroups.count == 1)
        #expect(report.duplicateGroups[0].count == 2)
    }

    @Test("L'ingestion peuple le catalogue et convertit les dossiers en collections")
    func ingest() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try CatalogDatabase(inMemory: ())
        let scanReport = LibraryScanner().scan(directory: root)
        let report = try Ingestor().ingest(report: scanReport, sourceFolder: root, into: db)

        #expect(report.scanned == 3)
        #expect(report.added == 3)
        #expect(report.recognized == 1)
        #expect(report.needsReview == 1)
        #expect(report.duplicates == 1)
        #expect(report.collectionsCreated == 1)

        // « Kant » apparaît dans le titre de l'œuvre reconnue ET dans le nom du
        // doublon (« copie de kant ») : la recherche doit trouver les deux.
        let byAuthor = try await CatalogSearch(db: db).works(matching: "Kant")
        #expect(byAuthor.count == 2)

        let byTitle = try await CatalogSearch(db: db).works(matching: "Critique")
        #expect(byTitle.count == 1)
        #expect(byTitle[0].authors == ["Kant"])

        let collections = try await db.pool.read { try BookCollection.fetchAll($0) }
        #expect(collections.map(\.name) == ["Philosophie allemande"])
    }

    @Test("Ré-ingérer est idempotent ; les fichiers disparus sortent avec leurs orphelins")
    func reingestAndRemoval() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try CatalogDatabase(inMemory: ())
        let ingestor = Ingestor()
        let scanner = LibraryScanner()

        _ = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)

        // Deuxième passage : rien ne bouge, rien ne se duplique.
        let second = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)
        #expect(second.added == 0)
        #expect(second.kept == 3)
        #expect(second.removed == 0)

        let countAfterSecond = try await db.pool.read { try Work.fetchCount($0) }
        #expect(countAfterSecond == 3)

        // Un fichier disparaît : son document, son édition et son œuvre aussi.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Kant_1781_Critique.pdf"))
        let third = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)
        #expect(third.removed == 1)
        #expect(third.kept == 2)

        let works = try await db.pool.read { try Work.fetchCount($0) }
        let editions = try await db.pool.read { try Edition.fetchCount($0) }
        let documents = try await db.pool.read { try Document.fetchCount($0) }
        #expect(works == 2)
        #expect(editions == 2)
        #expect(documents == 2)
    }

    @Test("LibraryOverview assemble lignes, statistiques et appartenances")
    func overview() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try CatalogDatabase(inMemory: ())
        _ = try Ingestor().ingest(report: LibraryScanner().scan(directory: root), sourceFolder: root, into: db)

        let overview = LibraryOverview(db: db)
        let rows = try await overview.rows()
        #expect(rows.count == 3)

        let kant = try #require(rows.first { $0.work.title.contains("Critique") })
        #expect(kant.authors == ["Kant"])
        #expect(kant.edition?.year == "1781")

        let stats = try await overview.stats()
        #expect(stats.total == 3)
        #expect(stats.recognized == 1)
        #expect(stats.needsReview == 1)
        #expect(stats.duplicates == 1)

        let membership = try await overview.membership()
        let collections = try await overview.collections()
        let philoId = try #require(collections.first?.id)
        #expect(membership.values.contains { $0.contains(philoId) })
    }
}

// MARK: - Étage 2 : métadonnées embarquées

@Suite("Entonnoir — étage métadonnées embarquées")
struct EmbeddedMetadataTests {
    @Test("Un PDF mal nommé mais bien renseigné est reconnu")
    func pdfInfo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-embedded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("scan_sans_nom_042.pdf")
        Fixtures.makePDF(at: url, title: "De la grammatologie", author: "Jacques Derrida")

        let guess = try #require(EmbeddedMetadata.read(fileURL: url, format: .pdf))
        #expect(guess.title == "De la grammatologie")
        #expect(guess.author == "Jacques Derrida")
        #expect(guess.confidence == .structured)
    }

    @Test("Les métadonnées machinales sont rejetées, pas proposées")
    func junkRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-junk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("document.pdf")
        Fixtures.makePDF(at: url, title: "Microsoft Word - final2.doc", author: "user")

        let guess = EmbeddedMetadata.read(fileURL: url, format: .pdf)
        #expect(guess == nil)
    }

    @Test("Un EPUB livre son Dublin Core : titre, auteur, année, ISBN, langue")
    func epubOPF() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("téléchargement(3).epub")
        try Fixtures.makeEPUB(
            at: url,
            title: "La Distinction",
            author: "Pierre Bourdieu",
            year: "1979",
            isbn13: "9782707302755"
        )

        let guess = try #require(EmbeddedMetadata.read(fileURL: url, format: .epub))
        #expect(guess.title == "La Distinction")
        #expect(guess.author == "Pierre Bourdieu")
        #expect(guess.year == "1979")
        #expect(guess.isbn13 == "9782707302755")
        #expect(guess.language == "fr")
        #expect(guess.publisher == "Éditions de test")
    }

    @Test("L'ingestion reconnaît un EPUB mal nommé grâce à l'étage 2")
    func ingestUsesEmbedded() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixtures.makeEPUB(
            at: dir.appendingPathComponent("téléchargement(3).epub"),
            title: "La Distinction",
            author: "Pierre Bourdieu",
            year: "1979",
            isbn13: "9782707302755"
        )

        let db = try CatalogDatabase(inMemory: ())
        let report = try Ingestor().ingest(
            report: LibraryScanner().scan(directory: dir),
            sourceFolder: dir,
            into: db
        )
        #expect(report.recognized == 1)
        #expect(report.needsReview == 0)

        let rows = try await LibraryOverview(db: db).rows()
        let row = try #require(rows.first)
        #expect(row.work.title == "La Distinction")
        #expect(row.authors == ["Pierre Bourdieu"])
        #expect(row.edition?.isbn13 == "9782707302755")
    }
}

// MARK: - Curation : la correction humaine

@Suite("Curation — la correction humaine fait autorité")
struct CatalogStoreTests {
    @Test("Corriger une fiche la rend reconnue, confiance haute")
    func applyUserEdit() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("scan illisible.pdf"))

        let db = try CatalogDatabase(inMemory: ())
        _ = try Ingestor().ingest(
            report: LibraryScanner().scan(directory: dir),
            sourceFolder: dir,
            into: db
        )

        let overview = LibraryOverview(db: db)
        let before = try #require(try await overview.rows().first)
        #expect(before.document.curationStatus == .needsReview)

        try await CatalogStore(db: db).applyUserEdit(
            workId: before.work.id,
            editionId: before.edition?.id,
            documentId: before.document.id,
            edit: RecordEdit(
                title: "Critique de la faculté de juger",
                authors: ["Kant, Immanuel"],
                year: "1790",
                isbn13: "9782080707109"
            )
        )

        let after = try #require(try await overview.rows().first)
        #expect(after.work.title == "Critique de la faculté de juger")
        #expect(after.authors == ["Kant, Immanuel"])
        #expect(after.edition?.year == "1790")
        #expect(after.document.curationStatus == .recognized)
        #expect(after.document.confidence == .high)
        #expect(after.work.confidence == .high)

        let stats = try await overview.stats()
        #expect(stats.needsReview == 0)
        #expect(stats.recognized == 1)
    }

    @Test("Ignorer un document ne touche pas ses métadonnées")
    func ignore() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes de cours.pdf"))

        let db = try CatalogDatabase(inMemory: ())
        _ = try Ingestor().ingest(
            report: LibraryScanner().scan(directory: dir),
            sourceFolder: dir,
            into: db
        )

        let overview = LibraryOverview(db: db)
        let row = try #require(try await overview.rows().first)
        try await CatalogStore(db: db).setStatus(.ignored, documentId: row.document.id)

        let after = try #require(try await overview.rows().first)
        #expect(after.document.curationStatus == .ignored)
        #expect(after.work.title == row.work.title)
    }
}
