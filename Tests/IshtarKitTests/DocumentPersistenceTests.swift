import Foundation
import Testing
import GRDB
import PDFKit
@testable import IshtarCatalog
@testable import IshtarIngest

@Suite("Persistance des documents et travail intellectuel (Lot I01)")
struct DocumentPersistenceTests {

    // MARK: - Helpers pour fixtures isolées

    private func makeTemporaryDirectory() throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-persistence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        return tempURL
    }

    private func makePDFData(title: String = "Test Document", author: String = "Test Author", text: String = "Contenu de test") -> Data {
        let pdfMeta = [
            kCGPDFContextTitle: title as CFString,
            kCGPDFContextAuthor: author as CFString,
        ]
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, pdfMeta as CFDictionary) else { return Data() }
        ctx.beginPage(mediaBox: &box)
        ctx.endPage()
        ctx.closePDF()

        // Si le texte est requis, on l'ajoute avec PDFKit si possible, sinon on injecte les octets
        if let pdfDoc = PDFDocument(data: data as Data), let page = pdfDoc.page(at: 0) {
            let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 180, height: 180), forType: .freeText, withProperties: nil)
            annotation.contents = text
            page.addAnnotation(annotation)
            return pdfDoc.dataRepresentation() ?? (data as Data)
        }
        return data as Data
    }

    private func makePDF(at url: URL, title: String = "Test Document", author: String = "Test Author", text: String = "Contenu de test") {
        let data = makePDFData(title: title, author: author, text: text)
        try? data.write(to: url)
    }

    // MARK: - C1 : Disparition et retour sans perte de travail intellectuel

    @Test("C1 — Un document disparu reste au catalogue (isMissing = true) avec tout son travail intellectuel, et est restauré au retour")
    func c1_disparitionEtRetourSansPerte() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Ingestion initiale
        let fileURL = root.appendingPathComponent("Spinoza_Ethique.pdf")
        makePDF(at: fileURL, title: "Éthique", author: "Spinoza", text: "Substantia est id quod in se est")

        let db = try CatalogDatabase(inMemory: ())
        let scanner = LibraryScanner()
        let ingestor = Ingestor()

        let report1 = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)
        #expect(report1.added == 1)

        let initialDoc = try await db.pool.read {
            try #require(try Document.fetchAll($0).first)
        }
        let initialDocId = initialDoc.id
        #expect(initialDoc.isMissing == false)

        // Ajout de travail intellectuel : annotations, projet, lien
        let annotationStore = AnnotationStore(db: db)
        let ann1 = try await annotationStore.add(Annotation(
            documentId: initialDocId,
            pageNumber: 1,
            quote: "Substantia est id quod in se est",
            note: "Définition capitale de la substance",
            color: "yellow"
        ))
        let ann2 = try await annotationStore.add(Annotation(
            documentId: initialDocId,
            pageNumber: 1,
            quote: "in se est et per se concipitur",
            note: "Deuxième moment de la définition",
            color: "blue"
        ))

        let projectStore = ProjectStore(db: db)
        let project = try await projectStore.add(Project(name: "Ontologie spinoziste"))
        try await projectStore.addDocument(initialDocId, toProjectId: project.id)

        let linkStore = LinkStore(db: db)
        _ = try await linkStore.add(Link(kind: "relation", projectId: project.id, sourceAnnotationId: ann1.id, targetAnnotationId: ann2.id))

        // 2. Disparition du fichier sur le disque
        try FileManager.default.removeItem(at: fileURL)

        // 3. Rescan : le document doit rester au catalogue sous isMissing = true
        let report2 = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)
        #expect(report2.scanned == 0)
        #expect(report2.missing == 1)
        #expect(report2.removed == 0)

        let docAfterVanish = try await db.pool.read {
            try #require(try Document.fetchOne($0, key: initialDocId))
        }
        #expect(docAfterVanish.isMissing == true)

        let worksCount = try await db.pool.read { try Work.fetchCount($0) }
        let editionsCount = try await db.pool.read { try Edition.fetchCount($0) }
        let docsCount = try await db.pool.read { try Document.fetchCount($0) }
        #expect(worksCount == 1)
        #expect(editionsCount == 1)
        #expect(docsCount == 1)

        let annotationsAfter = try await annotationStore.annotations(documentId: initialDocId)
        #expect(annotationsAfter.count == 2)
        #expect(annotationsAfter.first?.note == "Définition capitale de la substance")

        let projectItems = try await db.pool.read {
            try ProjectItem.filter(Column("projectId") == project.id).fetchAll($0)
        }
        #expect(projectItems.map { $0.documentId } == [initialDocId])

        let projectLinks = try await linkStore.links(forProjectId: project.id)
        #expect(projectLinks.count == 1)

        // 4. Retour du fichier à son emplacement d'origine
        makePDF(at: fileURL, title: "Éthique", author: "Spinoza", text: "Substantia est id quod in se est")

        let report3 = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)
        #expect(report3.scanned == 1)
        #expect(report3.recovered == 1)
        #expect(report3.missing == 0)

        let docAfterReturn = try await db.pool.read {
            try #require(try Document.fetchOne($0, key: initialDocId))
        }
        #expect(docAfterReturn.isMissing == false)
        #expect(docAfterReturn.id == initialDocId)

        let annotationsFinal = try await annotationStore.annotations(documentId: initialDocId)
        #expect(annotationsFinal.count == 2)
    }

    // MARK: - C2 : Renommage et déplacement non ambigus

    @Test("C2 — Renommage et déplacement non ambigus conservent l'identité et les annotations")
    func c2_renommageEtDeplacementNonAmbigus() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sub1 = root.appendingPathComponent("DossierA", isDirectory: true)
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        let originalURL = sub1.appendingPathComponent("Kant_1781.pdf")
        makePDF(at: originalURL, title: "Critique", author: "Kant", text: "Empreinte unique A1B2C3")

        let db = try CatalogDatabase(inMemory: ())
        let scanner = LibraryScanner()
        let ingestor = Ingestor()

        _ = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)

        let initialDoc = try await db.pool.read {
            try #require(try Document.fetchAll($0).first)
        }
        let docId = initialDoc.id

        // Annotation ancrée
        let annotationStore = AnnotationStore(db: db)
        _ = try await annotationStore.add(Annotation(
            documentId: docId,
            pageNumber: 1,
            quote: "Empreinte unique A1B2C3",
            note: "Citation sur Kant"
        ))

        // Déplacement et renommage vers DossierB/Critique_Deplacement.pdf
        let sub2 = root.appendingPathComponent("DossierB", isDirectory: true)
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)
        let movedURL = sub2.appendingPathComponent("Critique_Deplacement.pdf")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let reportMove = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)
        #expect(reportMove.relocated == 1)
        #expect(reportMove.added == 0)
        #expect(reportMove.removed == 0)
        #expect(reportMove.missing == 0)

        // Vérification de la préservation de l'identité
        let movedDoc = try await db.pool.read {
            try #require(try Document.fetchOne($0, key: docId))
        }
        #expect(movedDoc.id == docId)
        #expect(movedDoc.filePath == movedURL.standardizedFileURL.path)
        #expect(movedDoc.originalFileName == "Critique_Deplacement.pdf")
        #expect(movedDoc.isMissing == false)

        // Annotations toujours attachées
        let annotations = try await annotationStore.annotations(documentId: docId)
        #expect(annotations.count == 1)
        #expect(annotations.first?.quote == "Empreinte unique A1B2C3")
    }

    // MARK: - C3 : Scan incomplet ou inaccessible sans aucune perte

    @Test("C3 — Scan inaccessible ou incomplet (racine, parcours, lecture fichier) ne cause aucune perte et expose son état d'erreur")
    func c3_scanIncompletSansPerte() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            // Rétablir permissions pour nettoyage
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let fileURL = root.appendingPathComponent("Livre.pdf")
        makePDF(at: fileURL, title: "Titre", author: "Auteur")

        let db = try CatalogDatabase(inMemory: ())
        let scanner = LibraryScanner()
        let ingestor = Ingestor()

        _ = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)

        let initialDoc = try await db.pool.read { try #require(try Document.fetchAll($0).first) }
        #expect(!initialDoc.isMissing)

        // Cas 1 : Dossier inexistant / inaccessible dès la racine
        let nonexistentURL = root.appendingPathComponent("Inaccessible_\(UUID().uuidString)")
        let scanIncomplet1 = scanner.scan(directory: nonexistentURL)
        #expect(scanIncomplet1.isComplete == false)
        #expect(scanIncomplet1.hasScanErrors == true)
        #expect(scanIncomplet1.errorMessage != nil)

        let ingestReport1 = try ingestor.ingest(report: scanIncomplet1, sourceFolder: root, into: db)
        #expect(ingestReport1.isScanIncomplete == true)
        #expect(ingestReport1.missing == 0)

        // Cas 2 : Échec de lecture pendant le calcul SHA-256 (fichier sans droits de lecture)
        let unreadableFile = root.appendingPathComponent("Unreadable.pdf")
        makePDF(at: unreadableFile, title: "SansDroits", author: "X")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableFile.path)
        }

        let scanWithReadError = scanner.scan(directory: root)
        #expect(scanWithReadError.hasScanErrors == true)
        #expect(scanWithReadError.isComplete == false)
        #expect(scanWithReadError.errorMessage != nil)

        let ingestReport2 = try ingestor.ingest(report: scanWithReadError, sourceFolder: root, into: db)
        #expect(ingestReport2.isScanIncomplete == true)
        #expect(ingestReport2.missing == 0)
        #expect(ingestReport2.added == 0)

        // Cas 3 : Échec pendant le parcours d'un sous-dossier non énumérable
        let unreadableSubdir = root.appendingPathComponent("UnreadableDir", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableSubdir, withIntermediateDirectories: true)
        let nestedFile = unreadableSubdir.appendingPathComponent("Nested.pdf")
        makePDF(at: nestedFile, title: "Nested", author: "Y")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableSubdir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableSubdir.path)
        }

        let scanWithDirError = scanner.scan(directory: root)
        #expect(scanWithDirError.hasScanErrors == true)
        #expect(scanWithDirError.isComplete == false)

        let ingestReport3 = try ingestor.ingest(report: scanWithDirError, sourceFolder: root, into: db)
        #expect(ingestReport3.isScanIncomplete == true)

        // Le catalogue n'a subi AUCUNE mutation ni marquage introuvable erroné à travers tous ces échecs
        let docAfterFailedScans = try await db.pool.read { try #require(try Document.fetchOne($0, key: initialDoc.id)) }
        #expect(docAfterFailedScans.isMissing == false)
        #expect(docAfterFailedScans.filePath == fileURL.standardizedFileURL.path)
    }

    // MARK: - C4 : Doublons ambigus restent distincts sans fusion arbitraire

    @Test("C4 — Les doublons ambigus ne sont jamais fusionnés arbitrairement (copies octet-identiques, 2:1 et 1:2)")
    func c4_doublonsAmbigusRestentDistincts() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = LibraryScanner()
        let ingestor = Ingestor()

        // 1. Copie octet-identique et assertion d'empreintes égales
        let fileA = root.appendingPathComponent("CopieA.pdf")
        let fileB = root.appendingPathComponent("CopieB.pdf")
        let pdfBytes = makePDFData(title: "Doublon Parfait", author: "Auteur", text: "Texte strictement identique en octets")
        try pdfBytes.write(to: fileA)
        try pdfBytes.write(to: fileB)

        let hashA = LibraryScanner.sha256(of: fileA)
        let hashB = LibraryScanner.sha256(of: fileB)
        #expect(hashA != nil)
        #expect(hashA == hashB)

        // 2. Première ambiguïté : 2 anciens documents / 1 nouveau document avec notes distinctes
        let db2to1 = try CatalogDatabase(inMemory: ())
        _ = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db2to1)

        let initialDocs = try await db2to1.pool.read { try Document.order(Column("originalFileName")).fetchAll($0) }
        #expect(initialDocs.count == 2)
        let docA = initialDocs[0]
        let docB = initialDocs[1]

        let annotationStore2to1 = AnnotationStore(db: db2to1)
        _ = try await annotationStore2to1.add(Annotation(documentId: docA.id, pageNumber: 1, quote: "C1", note: "Note sur Copie A"))
        _ = try await annotationStore2to1.add(Annotation(documentId: docB.id, pageNumber: 1, quote: "C2", note: "Note sur Copie B"))

        // Les deux anciens fichiers disparaissent, et 1 seul nouveau fichier avec le même hash apparaît
        try FileManager.default.removeItem(at: fileA)
        try FileManager.default.removeItem(at: fileB)
        let fileNew = root.appendingPathComponent("NouveauUnique.pdf")
        try pdfBytes.write(to: fileNew)

        let report2to1 = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db2to1)
        #expect(report2to1.missing == 2)
        #expect(report2to1.relocated == 0) // Pas de réassociation arbitraire 2:1
        #expect(report2to1.added == 1)

        let docsAfter2to1 = try await db2to1.pool.read { try Document.fetchAll($0) }
        #expect(docsAfter2to1.count == 3) // 2 manquants + 1 nouveau

        let missingA = try await db2to1.pool.read { try Document.fetchOne($0, key: docA.id) }
        let missingB = try await db2to1.pool.read { try Document.fetchOne($0, key: docB.id) }
        #expect(missingA?.isMissing == true)
        #expect(missingB?.isMissing == true)

        let notesA = try await annotationStore2to1.annotations(documentId: docA.id)
        let notesB = try await annotationStore2to1.annotations(documentId: docB.id)
        #expect(notesA.first?.note == "Note sur Copie A")
        #expect(notesB.first?.note == "Note sur Copie B")

        // 3. Deuxième ambiguïté : 1 ancien document / 2 nouveaux documents avec note distincte
        let dir1to2 = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir1to2) }
        let fileSingle = dir1to2.appendingPathComponent("AncienSeul.pdf")
        try pdfBytes.write(to: fileSingle)

        let db1to2 = try CatalogDatabase(inMemory: ())
        _ = try ingestor.ingest(report: scanner.scan(directory: dir1to2), sourceFolder: dir1to2, into: db1to2)

        let docSingle = try await db1to2.pool.read { try #require(try Document.fetchAll($0).first) }
        let annotationStore1to2 = AnnotationStore(db: db1to2)
        _ = try await annotationStore1to2.add(Annotation(documentId: docSingle.id, pageNumber: 1, quote: "CS", note: "Note Ancien Seul"))

        // L'ancien disparaît, 2 nouveaux avec même hash apparaissent
        try FileManager.default.removeItem(at: fileSingle)
        let fileNew1 = dir1to2.appendingPathComponent("Nouveau1.pdf")
        let fileNew2 = dir1to2.appendingPathComponent("Nouveau2.pdf")
        try pdfBytes.write(to: fileNew1)
        try pdfBytes.write(to: fileNew2)

        let report1to2 = try ingestor.ingest(report: scanner.scan(directory: dir1to2), sourceFolder: dir1to2, into: db1to2)
        #expect(report1to2.missing == 1)
        #expect(report1to2.relocated == 0) // Pas de réassociation arbitraire 1:2
        #expect(report1to2.added == 2)

        let docSingleAfter = try await db1to2.pool.read { try Document.fetchOne($0, key: docSingle.id) }
        #expect(docSingleAfter?.isMissing == true)

        let notesSingle = try await annotationStore1to2.annotations(documentId: docSingle.id)
        #expect(notesSingle.first?.note == "Note Ancien Seul")

        let docsActive1to2 = try await db1to2.pool.read { try Document.filter(!Column("isMissing")).fetchAll($0) }
        #expect(docsActive1to2.count == 2)
        #expect(Set(docsActive1to2.map(\.originalFileName)) == Set(["Nouveau1.pdf", "Nouveau2.pdf"]))
    }

    // MARK: - C5 : Idempotence et compatibilité anciens catalogues

    @Test("C5 — Rescan inchangé idempotent et compatibilité des anciens catalogues v1-v5 avec vrai migrateur")
    func c5_idempotenceEtAnciensCatalogues() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        makePDF(at: root.appendingPathComponent("Doc1.pdf"), title: "Doc 1", author: "A1")
        makePDF(at: root.appendingPathComponent("Doc2.pdf"), title: "Doc 2", author: "A2")

        let db = try CatalogDatabase(inMemory: ())
        let scanner = LibraryScanner()
        let ingestor = Ingestor()

        let rep1 = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)
        #expect(rep1.added == 2)
        #expect(rep1.kept == 0)

        // Rescan 2
        let rep2 = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)
        #expect(rep2.added == 0)
        #expect(rep2.kept == 2)
        #expect(rep2.missing == 0)
        #expect(rep2.removed == 0)

        // Rescan 3
        let rep3 = try ingestor.ingest(report: scanner.scan(directory: root), sourceFolder: root, into: db)
        #expect(rep3.added == 0)
        #expect(rep3.kept == 2)
        #expect(rep3.missing == 0)
        #expect(rep3.removed == 0)

        let countDocs = try await db.pool.read { try Document.fetchCount($0) }
        #expect(countDocs == 2)

        // Test compatibilité : base créée avec le VRAI migrateur arrêté à v5_bibtex
        let oldDbFile = root.appendingPathComponent("real_v5.sqlite")
        let pool = try DatabasePool(path: oldDbFile.path)

        // On applique le vrai migrateur jusqu'à v5_projets_et_encres
        try CatalogDatabase.migrator.migrate(pool, upTo: "v5_projets_et_encres")

        // Insérer au schéma v5 : œuvre, édition, document, annotations, projet et lien
        let v5WorkId = UUID()
        let v5EditionId = UUID()
        let v5DocId = UUID()
        let v5AnnotationId = UUID()
        let v5Ann2Id = UUID()
        let v5ProjectId = UUID()

        try await pool.write { conn in
            // Work
            try conn.execute(sql: """
                INSERT INTO work (id, title, curationStatus, confidence)
                VALUES (?, ?, 'recognized', 'high')
                """, arguments: [v5WorkId, "Spinoza v5"])

            // Edition
            try conn.execute(sql: """
                INSERT INTO edition (id, workId, curationStatus, confidence, doi)
                VALUES (?, ?, 'recognized', 'high', '10.1000/spinoza')
                """, arguments: [v5EditionId, v5WorkId])

            // Document (schéma v5, sans colonne isMissing)
            try conn.execute(sql: """
                INSERT INTO document (id, editionId, filePath, originalFileName, fileSize, format, dateAdded, needsOCR, isTextExtracted, curationStatus, confidence)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'recognized', 'high')
                """, arguments: [
                    v5DocId,
                    v5EditionId,
                    "/legacy/spinoza_v5.pdf",
                    "spinoza_v5.pdf",
                    2048,
                    "pdf",
                    Date(),
                    false,
                    false
                ])

            // Annotation 1
            try conn.execute(sql: """
                INSERT INTO annotation (id, documentId, pageNumber, quote, note, color, dateCreated, dateModified)
                VALUES (?, ?, 1, 'Omnis determinatio est negatio', 'Note philosophique v5', 'yellow', ?, ?)
                """, arguments: [v5AnnotationId, v5DocId, Date(), Date()])

            // Annotation 2
            try conn.execute(sql: """
                INSERT INTO annotation (id, documentId, pageNumber, quote, note, color, dateCreated, dateModified)
                VALUES (?, ?, 2, 'Substantia prior est natura', 'Note deuxième', 'blue', ?, ?)
                """, arguments: [v5Ann2Id, v5DocId, Date(), Date()])

            // Project
            try conn.execute(sql: """
                INSERT INTO project (id, name, dateCreated, dateModified)
                VALUES (?, 'Grand Projet v5', ?, ?)
                """, arguments: [v5ProjectId, Date(), Date()])

            // ProjectItem
            try conn.execute(sql: """
                INSERT INTO project_item (projectId, documentId, dateAdded)
                VALUES (?, ?, ?)
                """, arguments: [v5ProjectId, v5DocId, Date()])

            // Link
            try conn.execute(sql: """
                INSERT INTO link (id, kind, color, projectId, sourceAnnotationId, targetAnnotationId, dateCreated, dateModified)
                VALUES (?, 'relation', 'yellow', ?, ?, ?, ?, ?)
                """, arguments: [UUID(), v5ProjectId, v5AnnotationId, v5Ann2Id, Date(), Date()])
        }

        // Rouvrir avec CatalogDatabase : la migration v6 s'exécute automatiquement
        let openedDb = try CatalogDatabase(at: oldDbFile)
        let appliedMigrations = try await openedDb.appliedMigrationIdentifiers()
        #expect(appliedMigrations.contains("v6_document_missing_state"))

        // Vérification de la conservation intégrale de toutes les entités
        let docMigre = try await openedDb.pool.read { try #require(try Document.fetchOne($0, key: v5DocId)) }
        #expect(docMigre.isMissing == false)
        #expect(docMigre.editionId == v5EditionId)
        #expect(docMigre.originalFileName == "spinoza_v5.pdf")

        let workMigre = try await openedDb.pool.read { try #require(try Work.fetchOne($0, key: v5WorkId)) }
        #expect(workMigre.title == "Spinoza v5")

        let annotationStore = AnnotationStore(db: openedDb)
        let annotations = try await annotationStore.annotations(documentId: v5DocId)
        #expect(annotations.count == 2)
        #expect(annotations.map { $0.id }.contains(v5AnnotationId))

        let projectItems = try await openedDb.pool.read {
            try ProjectItem.filter(Column("projectId") == v5ProjectId).fetchAll($0)
        }
        #expect(projectItems.map { $0.documentId } == [v5DocId])

        let linkStore = LinkStore(db: openedDb)
        let links = try await linkStore.links(forProjectId: v5ProjectId)
        #expect(links.count == 1)
        #expect(links.first?.sourceAnnotationId == v5AnnotationId)
        #expect(links.first?.targetAnnotationId == v5Ann2Id)
    }
}
