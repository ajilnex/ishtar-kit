import Foundation
import Testing
@testable import IshtarCatalog
@testable import IshtarIngest
@testable import IshtarSearch

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
