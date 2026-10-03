// Propre à macOS (cadres d'Apple ou démon) : hors de la suite Linux (WP-34).
#if canImport(Darwin)
import Foundation
import GRDB
import Testing
@testable import IshtarCatalog
@testable import IshtarIngest
@testable import IshtarDaemon
@testable import IshtarSearch

@Suite("Consolidation — intégrité des archives")
struct ArchiveIntegrityTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-integrity-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Une archive corrompue ne retire ni fiche ni note du catalogue ouvert")
    func corruptedArchiveKeepsCurrentCatalog() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = try CatalogDatabase(at: dir.appendingPathComponent("current.sqlite"))
        let work = Work(title: "Fiche vérifiée", notes: "Travail irremplaçable", confidence: .high)
        try await current.pool.write { conn in try work.insert(conn) }
        let archive = dir.appendingPathComponent("A.ishtar-archive")
        try await LibraryArchive.export(db: current, sourceFolderPath: nil, to: archive)
        try Data("ceci n’est pas SQLite".utf8).write(to: archive.appendingPathComponent("catalog.sqlite"))
        await #expect(throws: (any Error).self) {
            try await LibraryArchive.restore(from: archive, into: current, rebasingSourceTo: nil)
        }
        try await current.pool.read { (conn: Database) throws -> Void in
            #expect(try Work.fetchOne(conn, key: work.id)?.notes == "Travail irremplaçable")
            #expect(try Work.fetchOne(conn, key: work.id)?.confidence == .high)
        }
    }

    @Test("Restauration dans le pool ouvert, FTS et notes compris ; racine littérale avec _ et %")
    func restoreIntoLivePool() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try CatalogDatabase(at: dir.appendingPathComponent("source.sqlite"))
        let current = try CatalogDatabase(at: dir.appendingPathComponent("current.sqlite"))
        let root = "/source/A_%"
        let work = Work(title: "Livre conservé", confidence: .high)
        let edition = Edition(workId: work.id)
        let doc = Document(editionId: edition.id, filePath: root + "/livre.txt",
                           originalFileName: "livre.txt", fileSize: 20, format: .txt)
        let neighbour = Document(filePath: "/source/ABX/autre.txt", originalFileName: "autre.txt", fileSize: 1, format: .txt)
        let note = Annotation(documentId: doc.id, pageNumber: 1, quote: "citation retrouvable", note: "Ma note")
        try await source.pool.write { conn in
            try work.insert(conn); try edition.insert(conn); try doc.insert(conn); try neighbour.insert(conn)
            try SourceFolder(path: root).insert(conn)
            try DocumentPage(documentId: doc.id, pageNumber: 1, content: "citation retrouvable").insert(conn)
            try note.insert(conn)
        }
        let old = Work(title: "Avant restauration")
        try await current.pool.write { conn in try old.insert(conn) }
        // Échauffe une connexion de lecture avant le backup.
        #expect(try await current.pool.read { conn in try Work.fetchCount(conn) } == 1)
        let archive = dir.appendingPathComponent("A.ishtar-archive")
        try await LibraryArchive.export(db: source, sourceFolderPath: root, to: archive)
        try await LibraryArchive.restore(from: archive, into: current, rebasingSourceTo: "/nouvelle/racine")
        try await current.pool.read { (conn: Database) throws -> Void in
            #expect(try Work.fetchOne(conn, key: old.id) == nil)
            #expect(try Work.fetchOne(conn, key: work.id)?.confidence == .high)
            #expect(try Document.fetchOne(conn, key: doc.id)?.filePath == "/nouvelle/racine/livre.txt")
            #expect(try Document.fetchOne(conn, key: neighbour.id)?.filePath == neighbour.filePath)
            #expect(try Annotation.fetchOne(conn, key: note.id)?.note == "Ma note")
        }
        #expect(try await FulltextSearch(db: current).search("retrouvable").first?.documentId == doc.id)
    }

    @Test("Un manifeste incohérent et un format zéro sont refusés ; une sauvegarde existante reste intacte")
    func manifestAndDestinationSafety() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try CatalogDatabase(at: dir.appendingPathComponent("source.sqlite"))
        let archive = dir.appendingPathComponent("A.ishtar-archive")
        var manifest = try await LibraryArchive.export(db: db, sourceFolderPath: nil, to: archive)
        let original = try Data(contentsOf: archive.appendingPathComponent("catalog.sqlite"))
        await #expect(throws: LibraryArchive.LibraryArchiveError.destinationExists) {
            try await LibraryArchive.export(db: db, sourceFolderPath: nil, to: archive)
        }
        #expect(try Data(contentsOf: archive.appendingPathComponent("catalog.sqlite")) == original)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        manifest.documentCount += 1
        try encoder.encode(manifest).write(to: archive.appendingPathComponent("manifest.json"))
        await #expect(throws: (any Error).self) {
            try await LibraryArchive.restore(from: archive, into: db, rebasingSourceTo: nil)
        }
        manifest.formatVersion = 0
        try encoder.encode(manifest).write(to: archive.appendingPathComponent("manifest.json"))
        await #expect(throws: (any Error).self) {
            try await LibraryArchive.restore(from: archive, into: db, rebasingSourceTo: nil)
        }
    }
}

@Suite("Consolidation — extraction et preuves")
struct ExtractionIntegrityTests {
    @Test("Lecture impossible : les pages, notes et état d'attente sont conservés")
    func unreadablePreservesText() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let doc = Document(filePath: "/introuvable/\(UUID()).txt", originalFileName: "absent.txt", fileSize: 20, format: .txt)
        let note = Annotation(documentId: doc.id, quote: "Texte ancien", note: "Note conservée")
        try await db.pool.write { conn in
            try doc.insert(conn)
            try DocumentPage(documentId: doc.id, pageNumber: 1, content: "Texte ancien").insert(conn)
            try note.insert(conn)
        }
        await #expect(throws: (any Error).self) { try await ExtractionPipeline().extract(documentId: doc.id, into: db) }
        try await db.pool.read { (conn: Database) throws -> Void in
            #expect(try DocumentPage.fetchAll(conn).first?.content == "Texte ancien")
            #expect(try Annotation.fetchOne(conn, key: note.id)?.note == "Note conservée")
            #expect(try Document.fetchOne(conn, key: doc.id)?.isTextExtracted == false)
        }
    }

    @Test("Un OCR déjà annulé ne réécrit aucune page")
    func cancelledOCRPreservesText() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let doc = Document(filePath: "/absent.pdf", originalFileName: "absent.pdf", fileSize: 1, format: .pdf, needsOCR: true)
        try await db.pool.write { conn in
            try doc.insert(conn)
            try DocumentPage(documentId: doc.id, pageNumber: 1, content: "Ancien OCR").insert(conn)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OCRExtractor().extract(documentId: doc.id, into: db)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        try await db.pool.read { (conn: Database) throws -> Void in
            #expect(try DocumentPage.fetchAll(conn).first?.content == "Ancien OCR")
            #expect(try Document.fetchOne(conn, key: doc.id)?.needsOCR == true)
        }
    }

    @Test("Absence de texte, citation vide ou très courte : aucune preuve verte")
    func unverifiableCitations() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let doc = Document(filePath: "/livre.txt", originalFileName: "livre.txt", fileSize: 1, format: .txt)
        try await db.pool.write { conn in try doc.insert(conn) }
        let verifier = CitationVerifier(db: db)
        let raw = "[[cite:\(doc.id)|p=1|\"Une citation à prouver\"]]"
        let noText = await verifier.verify(text: raw)
        #expect(noText.first?.verdict.isVerified == false)
        #expect(noText.first?.verdict == .noTextAvailable(title: "livre.txt"))
        try await db.pool.write { conn in
            try DocumentPage(documentId: doc.id, pageNumber: 1, content: "Une citation à prouver").insert(conn)
        }
        for marker in ["[[cite:\(doc.id)|p=1]]", "[[cite:\(doc.id)|p=1|\"Une\"]]"] {
            #expect(await verifier.verify(text: marker).first?.verdict.isVerified == false)
        }
        #expect(await verifier.verify(text: raw).first?.verdict.isVerified == true)
        #expect(CitationVerifier.hasUnparsedMarkers(in: "[[cite:invalide|p=1]]"))
        #expect(!CitationVerifier.hasUnparsedMarkers(in: raw))
    }
}

@Suite("Consolidation — références, recherche et import")
struct ReferenceIntegrityTests {
    @Test("Un lien porte une édition, une page et une citation Unicode ; jamais un chemin reçu")
    func readingLinks() throws {
        let link = LibraryLink(reference: .edition("Adorno1951Minima-2003"), page: 42,
                               quote: "L’été : « une phrase & son sens »")
        #expect(LibraryLink(url: link.url) == link)
        let id = UUID()
        #expect(LibraryLink(url: LibraryLink(reference: .document(id), page: 2).url)?.reference == .document(id))
        for raw in ["file:///livre.pdf", "ishtar://document/../../etc/passwd", "ishtar://edition/Adorno%20MM", "ishtar://edition/Key?page=0", "ishtar://edition/Key?page=999999999999999999999", "ishtar://user:secret@edition/Key"] {
            #expect(LibraryLink(url: URL(string: raw)!) == nil)
        }
        #expect(LibraryLink.athanorCitation(key: "Adorno1951Minima") == "<Cite item=\"Adorno1951Minima\" />")
        #expect(LibraryLink.athanorCitation(key: "clé\"/>") == nil)
        #expect(LibraryLink.rayonsURL(base: "http://example.org", key: "Key") == nil)
        #expect(LibraryLink.rayonsURL(base: "https://rayons.kenoseme.fr", key: "Key")?.fragment == "Key")
    }

    @Test("L'export distingue citation et note personnelle et conserve le lien au passage")
    func notesExport() {
        let id = UUID()
        let note = Annotation(documentId: id, pageNumber: 2, quote: "Une citation\nsur deux lignes", note: "Mon *interprétation*")
        let markdown = AnnotationMarkdownExport.markdown(title: "Livre", citation: "Auteur, Livre (2003).",
                                                        editionKey: "Auteur2003Livre", annotations: [note])
        #expect(markdown.contains("> Une citation\n> sur deux lignes"))
        #expect(markdown.contains("**Note personnelle :**\n\nMon \\*interprétation\\*"))
        #expect(!markdown.contains("> Mon"))
        #expect(markdown.contains("ishtar://edition/Auteur2003Livre?page=2&quote="))
    }

    @Test("Le scan borne les racines littéralement et invalide le texte modifié sans perdre ses notes")
    func scanWildcardAndContentChange() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let root = URL(fileURLWithPath: "/library/A_%")
        let doc = Document(filePath: root.path + "/livre.txt", originalFileName: "livre.txt", fileSize: 20,
                           contentHash: "ancien", format: .txt, isTextExtracted: true, confidence: .high)
        let neighbour = Document(filePath: "/library/ABX/autre.txt", originalFileName: "autre.txt", fileSize: 1, format: .txt)
        let annotation = Annotation(documentId: doc.id, quote: "texte conservé", note: "note")
        try await db.pool.write { conn in
            try doc.insert(conn); try neighbour.insert(conn); try annotation.insert(conn)
            try DocumentPage(documentId: doc.id, pageNumber: 1, content: "texte conservé").insert(conn)
        }
        let file = ScannedFile(path: doc.filePath, fileName: doc.originalFileName, relativeFolder: "",
                               format: .txt, fileSize: 40, contentHash: "nouveau")
        _ = try Ingestor().ingest(report: ScanReport(files: [file]), sourceFolder: root, into: db)
        try await db.pool.read { (conn: Database) throws -> Void in
            let current = try #require(try Document.fetchOne(conn, key: doc.id))
            #expect(current.contentHash == "nouveau")
            #expect(current.fileSize == 40)
            #expect(!current.isTextExtracted)
            #expect(current.confidence == .high)
            #expect(try Annotation.fetchOne(conn, key: annotation.id)?.note == "note")
            #expect(try DocumentPage.fetchAll(conn).first?.content == "texte conservé")
            #expect(try Document.fetchOne(conn, key: neighbour.id)?.isMissing == false)
        }
    }

    @Test("Les vecteurs modifiés sont remplacés, les pages retirées purgées, les anciens index migrés")
    func vectorRevisions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-vectors-\(UUID()).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let store = try EmbeddingStore(at: url)
        try store.prepare(modelID: "fixture", dimension: 4)
        let a = EmbeddingStore.PageKey(documentId: UUID(), pageNumber: 1)
        let b = EmbeddingStore.PageKey(documentId: UUID(), pageNumber: 2)
        try store.insert([(a, [1, 0, 0, 0]), (b, [0, 1, 0, 0])], contentDigests: [a: "old", b: "gone"])
        try store.remove([a, b])
        try store.insert([(a, [0, 0, 1, 0])], contentDigests: [a: "new"])
        #expect(try store.indexedContentDigests() == [a: "new"])
        #expect(try store.nearest(to: [0, 0, 1, 0], limit: 1).first?.key == a)
        #expect(try store.nearest(to: [0, 0, 1, 0], limit: 0).isEmpty)
        try store.clear()
        #expect(try store.count() == 0)
        // Un index de la version précédente reste utilisable.
        try store.pool.write { conn in try conn.execute(sql: "ALTER TABLE page_map DROP COLUMN content_digest") }
        let migrated = try EmbeddingStore(at: url)
        #expect(try migrated.indexedContentDigests().isEmpty)
    }

    @Test("Deux fichiers homonymes ne deviennent pas une correspondance sûre BibTeX/Zotero")
    func ambiguousFileNames() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let a = Document(filePath: "/A/livre.pdf", originalFileName: "livre.pdf", fileSize: 1, format: .pdf)
        let b = Document(filePath: "/B/livre.pdf", originalFileName: "livre.pdf", fileSize: 1, format: .pdf)
        try await db.pool.read { conn in
            let matcher = DocumentMatcher()
            #expect(matcher.match(query: MatchQuery(fileNames: ["livre.pdf"]), documents: [a, b], editions: [], works: [], in: conn).document == nil)
            #expect(matcher.match(query: MatchQuery(fileNames: [a.filePath]), documents: [a, b], editions: [], works: [], in: conn).document?.id == a.id)
        }
    }

    @Test("Les polices EPUB obfusquées ne sont pas des DRM ; un chiffrement réel reste refusé")
    func epubFonts() {
        func xml(_ algorithm: String, _ path: String) -> Data {
            Data("<encryption xmlns:enc=\"http://www.w3.org/2001/04/xmlenc#\"><enc:EncryptedData><enc:EncryptionMethod Algorithm=\"\(algorithm)\"/><enc:CipherData><enc:CipherReference URI=\"\(path)\"/></enc:CipherData></enc:EncryptedData></encryption>".utf8)
        }
        #expect(FormatDetector.fontObfuscationOnly(xml("http://www.idpf.org/2008/embedding", "fonts/book.otf")))
        #expect(FormatDetector.fontObfuscationOnly(xml("http://ns.adobe.com/pdf/enc#RC", "fonts/book.ttf")))
        #expect(!FormatDetector.fontObfuscationOnly(xml("http://www.w3.org/2001/04/xmlenc#aes256-cbc", "chapter.xhtml")))
        #expect(!FormatDetector.fontObfuscationOnly(xml("http://www.idpf.org/2008/embedding", "chapter.xhtml")))
        #expect(!FormatDetector.fontObfuscationOnly(Data("endommagé".utf8)))
    }

    @Test("Une chaîne Word cyclique et une taille mensongère ne remplissent pas la mémoire")
    func malformedLegacyWord() {
        let data = Data(repeating: 65, count: 1024)
        #expect(CompoundFile.chain(data: data, fat: [0], sectorSize: 512, first: 0, size: 4_000_000_000).count == 512)
        #expect(CompoundFile.miniChain(miniStream: data, miniFAT: [0], miniSectorSize: 64, first: 0, size: 4_000_000_000).count == 64)
    }
}

@Suite("Consolidation — regroupements sans perte")
struct MergeIntegrityTests {
    @Test("La fusion préserve les notes, collections, brouillons étrangers et clés déjà utilisées")
    func mergePreservesWork() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let kept = Work(title: "Livre", notes: "Note principale")
        let absorbed = Work(title: "Livre ancien", notes: "Autre note")
        let draft = Work(title: "Brouillon sans fichier", notes: "À conserver")
        let a = Edition(workId: kept.id)
        let b = Edition(workId: absorbed.id)
        let da = Document(editionId: a.id, filePath: "/a.pdf", originalFileName: "a.pdf", fileSize: 1, format: .pdf)
        let dbb = Document(editionId: b.id, filePath: "/b.pdf", originalFileName: "b.pdf", fileSize: 1, format: .pdf)
        let collection = BookCollection(name: "Travail")
        let translator = Creator(name: "Traductrice à conserver")
        try await db.pool.write { conn in
            try kept.insert(conn); try absorbed.insert(conn); try draft.insert(conn)
            try a.insert(conn); try b.insert(conn); try da.insert(conn); try dbb.insert(conn)
            try collection.insert(conn); try CollectionItem(collectionId: collection.id, workId: absorbed.id).insert(conn)
            try translator.insert(conn)
            try EditionCreator(editionId: b.id, creatorId: translator.id, role: .translator).insert(conn)
            try AuthorityLink(entityType: .work, entityId: absorbed.id, scheme: .wikidata,
                              identifier: "Q123", status: .confirmed, evidence: "Source de test").insert(conn)
            try EditionKey(editionId: b.id, key: "LivreND", origin: .stable).insert(conn)
        }
        let store = CatalogStore(db: db)
        await #expect(throws: (any Error).self) { try await store.merge(duplicates: [dbb.id], into: da.id) }
        #expect(try await store.key(forEdition: b.id)?.key == "LivreND")
        try await db.pool.write { conn in try conn.execute(sql: "UPDATE edition_key SET origin = 'generated'") }
        try await store.merge(duplicates: [dbb.id], into: da.id)
        try await db.pool.read { (conn: Database) throws -> Void in
            let notes = try #require(Work.fetchOne(conn, key: kept.id)?.notes)
            #expect(notes.contains("Note principale") && notes.contains("Autre note"))
            #expect(try Work.fetchOne(conn, key: draft.id)?.notes == "À conserver")
            #expect(try CollectionItem.filter(Column("workId") == kept.id).fetchCount(conn) == 1)
            #expect(try EditionCreator.filter(Column("editionId") == a.id).fetchCount(conn) == 1)
            #expect(try AuthorityLink.filter(Column("entityId") == kept.id).fetchCount(conn) == 1)
            #expect(try AuthorityLink.filter(Column("entityId") == absorbed.id).fetchCount(conn) == 0)
        }
    }

    @Test("Même titre et même année, éditeurs incompatibles : aucune fusion mécanique")
    func publishersStayDistinct() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let work = Work(title: "Un livre")
        try await db.pool.write { conn in
            try work.insert(conn)
            for publisher in ["Éditeur A", "Éditeur B"] {
                let edition = Edition(workId: work.id, publisher: publisher, year: "2003", language: "fr")
                try edition.insert(conn)
                try Document(editionId: edition.id, filePath: "/\(publisher).pdf", originalFileName: "\(publisher).pdf", fileSize: 1, format: .pdf).insert(conn)
            }
        }
        #expect(try await EditionGrouping.proposals(in: db).isEmpty)
    }

    @Test("Deux traductions homonymes de même année restent deux éditions")
    func languagesStayDistinct() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let work = Work(title: "Minima moralia")
        try await db.pool.write { conn in
            try work.insert(conn)
            for language in ["fr", "de"] {
                let edition = Edition(workId: work.id, year: "2003", language: language)
                try edition.insert(conn)
                try Document(editionId: edition.id, filePath: "/\(language).pdf", originalFileName: "\(language).pdf", fileSize: 1, format: .pdf).insert(conn)
            }
        }
        #expect(try await EditionGrouping.proposals(in: db).isEmpty)
    }
}
#endif
