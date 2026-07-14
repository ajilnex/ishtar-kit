import Foundation
import GRDB
import Testing
@testable import IshtarCatalog
@testable import IshtarIngest
@testable import IshtarSearch

// MARK: - Plein texte : extraction et recherche FTS5 (WP-03a+3b)

@Suite("Plein texte — extraction et recherche FTS5")
struct FulltextTests {
    /// Un dossier temporaire, nettoyé par l'appelant.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-fts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Ingère le dossier puis renvoie le premier (unique) document catalogué.
    private func ingestSingle(from dir: URL) throws -> (CatalogDatabase, Document) {
        let db = try CatalogDatabase(inMemory: ())
        _ = try Ingestor().ingest(
            report: LibraryScanner().scan(directory: dir),
            sourceFolder: dir,
            into: db
        )
        let document = try db.pool.read { try Document.fetchOne($0) }
        return (db, try #require(document))
    }

    private func pageCount(of documentId: UUID, in db: CatalogDatabase) async throws -> Int {
        try await db.pool.read {
            try DocumentPage.filter(Column("documentId") == documentId).fetchCount($0)
        }
    }

    @Test("EPUB : extraction des pages, puis la recherche FTS retrouve un mot au bon numéro de page")
    func epubExtractionAndSearch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixtures.makeEPUB(
            at: dir.appendingPathComponent("livre.epub"),
            title: "La Dialectique",
            author: "Georg Hegel",
            year: "1807",
            isbn13: nil,
            bodyText: "La dialectique est le mouvement de la contradiction. "
                + "La conscience se dépasse elle-même dans ce mouvement."
        )

        let (db, document) = try ingestSingle(from: dir)
        try await ExtractionPipeline().extract(documentId: document.id, into: db)

        #expect(try await pageCount(of: document.id, in: db) == 1)

        let hits = try await FulltextSearch(db: db).search("dialectique")
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.documentId == document.id)
        #expect(hit.pageNumber == 1)
        #expect(hit.title == "La Dialectique")
        #expect(hit.authors == ["Georg Hegel"])
        #expect(hit.snippet.contains("«")) // le terme est cerné en contexte

        let refreshed = try #require(try await db.pool.read { try Document.fetchOne($0, key: document.id) })
        #expect(refreshed.isTextExtracted)
        #expect(!refreshed.needsOCR)
    }

    @Test("TXT : découpage en pages, recherche avec diacritiques repliés (verite → vérité)")
    func txtPaginationAndDiacritics() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Un paragraphe court, puis un long qui force plusieurs pages (> 4000 car.).
        let long = String(repeating: "La vérité de l'être se dévoile lentement au penseur. ", count: 200)
        let content = "Introduction brève au propos.\n\n" + long
        try Data(content.utf8).write(to: dir.appendingPathComponent("Heidegger_1927_Etre-et-temps.txt"))

        let (db, document) = try ingestSingle(from: dir)
        try await ExtractionPipeline().extract(documentId: document.id, into: db)

        // Le long paragraphe est coupé : au moins deux pages.
        #expect(try await pageCount(of: document.id, in: db) >= 2)

        // Saisie sans accents : FTS replie les diacritiques et retrouve « vérité ».
        let hits = try await FulltextSearch(db: db).search("verite")
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.documentId == document.id })
    }

    @Test("Idempotence : extraire deux fois ne duplique aucune page")
    func idempotentExtraction() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = "Premier paragraphe.\n\nDeuxième paragraphe avec le mot rare xylophone."
        try Data(content.utf8).write(to: dir.appendingPathComponent("Notes_ND_texte.md"))

        let (db, document) = try ingestSingle(from: dir)
        let pipeline = ExtractionPipeline()

        try await pipeline.extract(documentId: document.id, into: db)
        let first = try await pageCount(of: document.id, in: db)
        #expect(first > 0)

        try await pipeline.extract(documentId: document.id, into: db)
        let second = try await pageCount(of: document.id, in: db)
        #expect(second == first)

        // La recherche reste cohérente (un seul passage, pas de doublon).
        let hits = try await FulltextSearch(db: db).search("xylophone")
        #expect(hits.count == 1)
    }

    @Test("PDF sans texte : needsOCR, zéro page indexée")
    func scannedPDFNeedsOCR() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Un PDF à page vierge : aucune couche texte (page.string vide) → scan.
        Fixtures.makePDF(at: dir.appendingPathComponent("scan_brut.pdf"), title: nil, author: nil)

        let (db, document) = try ingestSingle(from: dir)
        #expect(document.format == .pdf)

        try await ExtractionPipeline().extract(documentId: document.id, into: db)

        let refreshed = try #require(try await db.pool.read { try Document.fetchOne($0, key: document.id) })
        #expect(refreshed.needsOCR)
        #expect(refreshed.isTextExtracted)
        #expect(try await pageCount(of: document.id, in: db) == 0)
    }

    @Test("Une saisie brute pleine de caractères FTS5 ne fait jamais planter la requête")
    func rawQueryIsNeutralized() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("Le concept de liberté chez Sartre.".utf8)
            .write(to: dir.appendingPathComponent("Sartre_ND_liberte.txt"))

        let (db, document) = try ingestSingle(from: dir)
        try await ExtractionPipeline().extract(documentId: document.id, into: db)

        // Guillemets, astérisques, deux-points, parenthèses, accent circonflexe :
        // neutralisés autour d'un terme réel, la requête aboutit sans planter.
        let hits = try await FulltextSearch(db: db).search("\"liberté*\" : (^)")
        #expect(hits.count == 1)
        #expect(hits.first?.documentId == document.id)
    }
}
