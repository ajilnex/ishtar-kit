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

    /// Un EPUB minimal : container.xml + OPF Dublin Core. Si `bodyText` est fourni,
    /// on ajoute un item de spine XHTML porteur de ce texte (pour tester l'extraction).
    static func makeEPUB(
        at url: URL,
        title: String,
        author: String,
        year: String,
        isbn13: String?,
        bodyText: String? = nil
    ) throws {
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

        // Un chapitre XHTML optionnel, référencé par le manifest et le spine.
        var extraFiles: [(String, String)] = []
        var manifestItems = ""
        var spineItems = ""
        if let bodyText {
            let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>\(title)</title></head>
              <body><p>\(bodyText)</p></body>
            </html>
            """
            extraFiles.append(("OEBPS/chapter1.xhtml", xhtml))
            manifestItems = #"<item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>"#
            spineItems = #"<itemref idref="ch1"/>"#
        }

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
          <manifest>\(manifestItems)</manifest>
          <spine>\(spineItems)</spine>
        </package>
        """

        for (path, content) in [("META-INF/container.xml", container), ("OEBPS/content.opf", opf)] + extraFiles {
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

    @Test("Convention Z-Library avec auteur → structured")
    func zLibraryWithAuthor() {
        let hegel = FilenameParser.parse(fileName: "Hegel, les actes de lesprit (Bernard Bourgeois) (Z-Library).pdf")
        #expect(hegel.confidence == .structured)
        #expect(hegel.title == "Hegel, les actes de lesprit")
        #expect(hegel.author == "Bernard Bourgeois")

        // Doublons entre crochets et marqueur de copie « (1) ».
        let derrida = FilenameParser.parse(fileName: "Marges – de la philosophie (Derrida, Jacques [Derrida, Jacques]) (Z-Library)(1).epub")
        #expect(derrida.confidence == .structured)
        #expect(derrida.title == "Marges – de la philosophie")
        #expect(derrida.author == "Derrida, Jacques")

        // Annotation nichée « (editor) » et variante Z-lib.org.
        let webb = FilenameParser.parse(fileName: "The Nature of Reality (Richard Webb (editor)) (Z-lib.org).pdf")
        #expect(webb.confidence == .structured)
        #expect(webb.author == "Richard Webb")
        #expect(webb.title == "The Nature of Reality")
    }

    @Test("Z-Library sans auteur fiable → repli titre propre")
    func zLibraryDoubtfulAuthor() {
        // Dernière parenthèse = marqueur d'édition, pas un nom.
        let edition = FilenameParser.parse(fileName: "L'Attaque des Titans Chapitre 1 (French Edition) (Z-Library).epub")
        #expect(edition.confidence == .fallback)
        #expect(edition.author == nil)
        #expect(edition.title == "L'Attaque des Titans Chapitre 1")

        // Dernière parenthèse = année seule.
        let year = FilenameParser.parse(fileName: "Un manuscrit anonyme (2019) (Z-Library).pdf")
        #expect(year.confidence == .fallback)
        #expect(year.author == nil)
        #expect(year.title == "Un manuscrit anonyme")
    }

    @Test("Convention Scribd → repli avec titre nettoyé sans l'ID")
    func scribdNumericPrefix() {
        let foucault = FilenameParser.parse(fileName: "111503479-Surveiller-et-Punir.pdf")
        #expect(foucault.confidence == .fallback)
        #expect(foucault.author == nil)
        #expect(foucault.title == "Surveiller et Punir")

        let derrida = FilenameParser.parse(fileName: "168204597-Derrida-Jacques-La-Voix-et-le-Phenomene.pdf")
        #expect(derrida.confidence == .fallback)
        #expect(derrida.title == "Derrida Jacques La Voix et le Phenomene")
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

    @Test("Les dossiers annexes « *.sdr » sont ignorés : ni documents, ni non-gérés")
    func skipsSidecarFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-sdr-\(UUID().uuidString)")
        let sidecar = root.appendingPathComponent("Lettre au père (Franz Kafka) (Z-Library).sdr")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Un vrai document à la racine, et deux fichiers cachés dans le dossier annexe.
        try Data("livre".utf8).write(to: root.appendingPathComponent("Kant_1781_Critique.pdf"))
        try Data("annexe".utf8).write(to: sidecar.appendingPathComponent("cdeKey.pdf"))
        try Data("annexe".utf8).write(to: sidecar.appendingPathComponent("state.dat"))

        let report = LibraryScanner(computeHashes: false).scan(directory: root)
        #expect(report.files.count == 1)
        #expect(report.files.first?.fileName == "Kant_1781_Critique.pdf")
        // Le PDF du dossier annexe ne compte pas comme document ; le .dat ne compte
        // pas comme non-géré : le dossier .sdr est intégralement écarté.
        #expect(report.unsupportedCount == 0)
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

    @Test("repropose rejoue l'entonnoir sans rien écrire")
    func repropose() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-repropose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("contenu de test".utf8)
            .write(to: dir.appendingPathComponent("Kant_1781_Critique de la raison pure.txt"))

        let db = try CatalogDatabase(inMemory: ())
        _ = try Ingestor().ingest(
            report: LibraryScanner().scan(directory: dir),
            sourceFolder: dir,
            into: db
        )

        let overview = LibraryOverview(db: db)
        let row = try #require(try await overview.rows().first)
        let doc = row.document

        // Correction humaine : la fiche s'éloigne de la proposition mécanique.
        try await CatalogStore(db: db).applyUserEdit(
            workId: row.work.id,
            editionId: row.edition?.id,
            documentId: doc.id,
            edit: RecordEdit(title: "Titre corrigé", authors: ["Humain"])
        )

        // Rejouer l'entonnoir retrouve la proposition d'origine.
        let guess = try await Ingestor().repropose(documentId: doc.id, into: db)
        #expect(guess?.title == "Critique de la raison pure")
        #expect(guess?.author == "Kant")
        #expect(guess?.year == "1781")

        // Preuve de non-écriture : la fiche corrigée est intacte, statut et
        // confiance inchangés, aucun enregistrement créé ni supprimé.
        let after = try #require(try await overview.rows().first)
        #expect(after.work.title == "Titre corrigé")
        #expect(after.authors == ["Humain"])
        #expect(after.document.curationStatus == .recognized)
        #expect(after.work.confidence == .high)

        let works = try await db.pool.read { try Work.fetchCount($0) }
        let editions = try await db.pool.read { try Edition.fetchCount($0) }
        let documents = try await db.pool.read { try Document.fetchCount($0) }
        #expect(works == 1)
        #expect(editions == 1)
        #expect(documents == 1)

        // Document inconnu : nil, toujours sans écriture.
        let missing = try await Ingestor().repropose(documentId: UUID(), into: db)
        #expect(missing == nil)
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

    @Test("Fusion des doublons puis détachement : rattacher, ramasser, réversible")
    func mergeAndDetach() async throws {
        let db = try CatalogDatabase(inMemory: ())

        // Deux triplets work/edition/document, MÊME contenu (SHA-256 « abc »).
        let workA = Work(title: "Titre brut A", curationStatus: .duplicateCandidate, confidence: .low)
        let editionA = Edition(workId: workA.id, curationStatus: .duplicateCandidate, confidence: .low)
        let docA = Document(
            editionId: editionA.id,
            filePath: "/tmp/A.pdf",
            originalFileName: "A.pdf",
            fileSize: 10,
            contentHash: "abc",
            format: .pdf,
            curationStatus: .duplicateCandidate,
            confidence: .low
        )
        let workB = Work(title: "Titre brut B", curationStatus: .duplicateCandidate, confidence: .low)
        let editionB = Edition(workId: workB.id, curationStatus: .duplicateCandidate, confidence: .low)
        let docB = Document(
            editionId: editionB.id,
            filePath: "/tmp/Copie de A.pdf",
            originalFileName: "Copie de A.pdf",
            fileSize: 10,
            contentHash: "abc",
            format: .pdf,
            curationStatus: .duplicateCandidate,
            confidence: .low
        )
        try await db.pool.write { conn in
            for work in [workA, workB] { try work.insert(conn) }
            for edition in [editionA, editionB] { try edition.insert(conn) }
            for document in [docA, docB] { try document.insert(conn) }
        }

        // Correction humaine de A : c'est elle qui doit primer.
        try await CatalogStore(db: db).applyUserEdit(
            workId: workA.id,
            editionId: editionA.id,
            documentId: docA.id,
            edit: RecordEdit(title: "Le vrai titre", authors: ["Autrice"])
        )

        // Fusion : B rejoint l'édition de A, orphelins ramassés.
        try await CatalogStore(db: db).merge(duplicates: [docB.id], into: docA.id)

        try await db.pool.read { conn in
            let mergedB = try #require(try Document.fetchOne(conn, key: docB.id))
            #expect(mergedB.editionId == editionA.id)
            #expect(mergedB.curationStatus == .recognized)
            #expect(mergedB.confidence == .high)
            #expect(try Work.fetchCount(conn) == 1)
            #expect(try Edition.fetchCount(conn) == 1)
            let survivingWork = try #require(try Work.fetchOne(conn, key: workA.id))
            #expect(survivingWork.title == "Le vrai titre")
        }

        // Rien n'a touché le disque : les fichiers n'existent pas.
        #expect(!FileManager.default.fileExists(atPath: docA.filePath))
        #expect(!FileManager.default.fileExists(atPath: docB.filePath))

        // Détachement : B retrouve une fiche neuve, réversibilité.
        try await CatalogStore(db: db).detach(documentId: docB.id)

        try await db.pool.read { conn in
            let detachedB = try #require(try Document.fetchOne(conn, key: docB.id))
            #expect(detachedB.editionId != editionA.id)
            let newEditionId = try #require(detachedB.editionId)
            #expect(detachedB.curationStatus == .needsReview)
            #expect(detachedB.confidence == .low)
            #expect(try Work.fetchCount(conn) == 2)
            let newEdition = try #require(try Edition.fetchOne(conn, key: newEditionId))
            let newWork = try #require(try Work.fetchOne(conn, key: newEdition.workId))
            #expect(newWork.title == "Copie de A")

            // La fiche de A est intacte.
            let keptWork = try #require(try Work.fetchOne(conn, key: workA.id))
            #expect(keptWork.title == "Le vrai titre")
            #expect(keptWork.curationStatus == .recognized)
            #expect(keptWork.confidence == .high)
        }

        // Fusionner avec l'id conservé dans la liste : sans effet ni erreur.
        try await CatalogStore(db: db).merge(duplicates: [docA.id], into: docA.id)
        try await db.pool.read { conn in
            let keptA = try #require(try Document.fetchOne(conn, key: docA.id))
            #expect(keptA.editionId == editionA.id)
        }
    }
}

// MARK: - Archive — export/import de bibliothèque

@Suite("Archive — export/import de bibliothèque")
struct LibraryArchiveTests {
    /// Round-trip complet : export d'une base peuplée, réimport dans un
    /// nouveau catalogue avec rebasage des chemins vers un autre dossier source.
    @Test("Round-trip parfait avec rebasage des chemins de documents")
    func roundTripWithRebase() async throws {
        let db = try CatalogDatabase(inMemory: ())

        let work = Work(title: "Critique de la raison pure",
                        curationStatus: .recognized, confidence: .high)
        let edition = Edition(workId: work.id, publisher: "PUF", year: "1944")
        let document = Document(
            editionId: edition.id,
            filePath: "/ancien/racine/Philo/K.pdf",
            originalFileName: "K.pdf",
            fileSize: 4096,
            format: .pdf
        )
        try await db.pool.write { conn in
            try work.insert(conn)
            try edition.insert(conn)
            try document.insert(conn)
            try conn.execute(sql: """
                INSERT INTO document_page(documentId, pageNumber, content)
                VALUES (?, 1, 'Les intuitions sans concepts sont aveugles.')
                """, arguments: [document.id])
            try SourceFolder(path: "/ancien/racine").insert(conn)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent("Test.ishtar-archive", isDirectory: true)
        let manifest = try await LibraryArchive.export(
            db: db, sourceFolderPath: "/ancien/racine", to: archiveURL)

        #expect(manifest.formatVersion == 1)
        #expect(manifest.documentCount == 1)
        #expect(manifest.appliedMigrations == CatalogDatabase.knownMigrationIdentifiers)
        #expect(FileManager.default.fileExists(
            atPath: archiveURL.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(
            atPath: archiveURL.appendingPathComponent("catalog.sqlite").path))

        let restoredURL = tempDir.appendingPathComponent("restaure.sqlite")
        _ = try await LibraryArchive.importArchive(
            from: archiveURL, toCatalogAt: restoredURL,
            rebasingSourceTo: "/nouveau/chez-moi")

        let restored = try CatalogDatabase(at: restoredURL)
        try await restored.pool.read { conn in
            #expect(try Work.fetchCount(conn) == 1)
            let fetchedWork = try #require(try Work.fetchOne(conn, key: work.id))
            #expect(fetchedWork.title == "Critique de la raison pure")

            #expect(try Document.fetchCount(conn) == 1)
            let fetchedDoc = try #require(try Document.fetchOne(conn, key: document.id))
            #expect(fetchedDoc.filePath == "/nouveau/chez-moi/Philo/K.pdf")

            let pageContent = try String.fetchOne(conn, sql: """
                SELECT content FROM document_page WHERE documentId = ? AND pageNumber = 1
                """, arguments: [document.id])
            #expect(pageContent == "Les intuitions sans concepts sont aveugles.")

            let folderPath = try String.fetchOne(conn, sql: "SELECT path FROM source_folder")
            #expect(folderPath == "/nouveau/chez-moi")
        }
    }

    /// L'import refuse proprement les archives venues d'une version future.
    @Test("Refus des versions futures : format et migrations inconnues")
    func rejectsFutureVersions() async throws {
        let db = try CatalogDatabase(inMemory: ())

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent("Test.ishtar-archive", isDirectory: true)
        _ = try await LibraryArchive.export(db: db, sourceFolderPath: nil, to: archiveURL)

        let manifestURL = archiveURL.appendingPathComponent("manifest.json")
        let restoredURL = tempDir.appendingPathComponent("restaure.sqlite")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Migration inconnue → .futureSchema.
        var future = try decoder.decode(
            LibraryArchive.Manifest.self, from: Data(contentsOf: manifestURL))
        future.appliedMigrations.append("v99_future")
        try encoder.encode(future).write(to: manifestURL)

        await #expect(throws: LibraryArchive.LibraryArchiveError.futureSchema(["v99_future"])) {
            try await LibraryArchive.importArchive(
                from: archiveURL, toCatalogAt: restoredURL, rebasingSourceTo: nil)
        }

        // Format futur → .futureFormat.
        var futureFormat = try decoder.decode(
            LibraryArchive.Manifest.self, from: Data(contentsOf: manifestURL))
        futureFormat.appliedMigrations = CatalogDatabase.knownMigrationIdentifiers
        futureFormat.formatVersion = 2
        try encoder.encode(futureFormat).write(to: manifestURL)

        await #expect(throws: LibraryArchive.LibraryArchiveError.futureFormat(2)) {
            try await LibraryArchive.importArchive(
                from: archiveURL, toCatalogAt: restoredURL, rebasingSourceTo: nil)
        }
    }
}

// MARK: - Étage 3 : connecteur Crossref

@Suite("Entonnoir — étage 3 : connecteur Crossref (décodage pur)")
struct CrossrefConnectorTests {
    /// Extrait réaliste d'une réponse /works : aucun réseau, on teste `parse`.
    static let worksJSON = Data("""
    {"status":"ok","message":{"DOI":"10.1017/cbo9780511806223","ISBN":["978-0-521-58836-1"],"title":["Moses the Egyptian"],"author":[{"given":"Jan","family":"Assmann"},{"family":"Collectif"}],"issued":{"date-parts":[[1997,3]]},"publisher":"Cambridge University Press","language":"en"}}
    """.utf8)

    @Test("Décode titre, auteurs, année, éditeur, langue, ISBN-13 et DOI")
    func decodeReponseComplete() throws {
        let guess = try #require(CrossrefConnector.parse(worksResponse: Self.worksJSON))
        #expect(guess.title == "Moses the Egyptian")
        #expect(guess.author == "Jan Assmann ; Collectif")
        #expect(guess.year == "1997")
        #expect(guess.publisher == "Cambridge University Press")
        #expect(guess.language == "en")
        #expect(guess.isbn13 == "9780521588361")
        #expect(guess.doi == "10.1017/cbo9780511806223")
        #expect(guess.confidence == .structured)
    }

    @Test("Sans titre : aucune proposition")
    func sansTitreRendNil() {
        let json = Data(#"{"message":{"publisher":"Cambridge University Press"}}"#.utf8)
        #expect(CrossrefConnector.parse(worksResponse: json) == nil)
    }

    @Test("Données non-JSON : aucune proposition")
    func nonJSONRendNil() {
        let json = Data("ceci n'est pas du JSON".utf8)
        #expect(CrossrefConnector.parse(worksResponse: json) == nil)
    }
}

// MARK: - Étage 3 : connecteur OpenLibrary

@Suite("Entonnoir — étage 3 : connecteur OpenLibrary (décodage pur)")
struct OpenLibraryConnectorTests {
    /// Extrait réaliste d'une réponse /api/books (jscmd=data) : aucun réseau.
    static let booksJSON = Data("""
    {"ISBN:9780674727779":{"title":"The Ancient City","authors":[{"name":"Numa Denis Fustel de Coulanges"}],"publish_date":"March 1997","publishers":[{"name":"Harvard University Press"}],"identifiers":{"isbn_13":["9780674727779"]}}}
    """.utf8)

    @Test("Décode titre, auteur, année, éditeur, ISBN-13")
    func decodeReponseComplete() throws {
        let guess = try #require(
            OpenLibraryConnector.parse(booksResponse: Self.booksJSON, isbn: "9780674727779"))
        #expect(guess.title == "The Ancient City")
        #expect(guess.author == "Numa Denis Fustel de Coulanges")
        #expect(guess.year == "1997")
        #expect(guess.publisher == "Harvard University Press")
        #expect(guess.isbn13 == "9780674727779")
        #expect(guess.confidence == .structured)
    }

    @Test("ISBN inconnu (objet vide) : aucune proposition")
    func objetVideRendNil() {
        let json = Data("{}".utf8)
        #expect(OpenLibraryConnector.parse(booksResponse: json, isbn: "9780674727779") == nil)
    }

    @Test("Sans titre : aucune proposition")
    func sansTitreRendNil() {
        let json = Data(#"{"ISBN:9780674727779":{"publishers":[{"name":"Harvard University Press"}]}}"#.utf8)
        #expect(OpenLibraryConnector.parse(booksResponse: json, isbn: "9780674727779") == nil)
    }
}
