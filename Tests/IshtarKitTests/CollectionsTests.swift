import Foundation
import Testing
import GRDB
@testable import IshtarCatalog
@testable import IshtarSearch

@Suite("Collections et exemplaires établis sur pièces")
struct CollectionsTests {
    func seed(_ db: CatalogDatabase) async throws -> (UUID, UUID) {
        try await db.pool.write { conn in
            let work = Work(title: "Cahier des figures")
            let author = Creator(name: "Alice Exemple")
            let edition = Edition(workId: work.id)
            let doc = Document(editionId: edition.id, filePath: "/fixture/Cahier.pdf", originalFileName: "Cahier.pdf", fileSize: 123, contentHash: String(repeating: "a", count: 64), format: .pdf)
            try work.insert(conn); try author.insert(conn)
            try WorkCreator(workId: work.id, creatorId: author.id).insert(conn)
            try edition.insert(conn); try doc.insert(conn)
            try EditionKey.assignMissing(conn)
            try Annotation(documentId: doc.id, pageNumber: 2, quote: "Une figure").insert(conn)
            return (edition.id, doc.id)
        }
    }

    @Test("Une collection est idempotente, ne clone ni document ni annotation et annule une clé inconnue")
    func linksOnly() async throws {
        let db = try CatalogDatabase(inMemory: ())
        _ = try await seed(db)
        let key = try await db.pool.read { try String.fetchOne($0, sql: "SELECT key FROM edition_key")! }
        let store = CollectionStore(db: db)
        #expect(try await store.add(keys: [key], to: "Atelier", apply: false) == nil)
        let id = try await store.add(keys: [key, key], to: "Atelier", apply: true)
        #expect(try await store.add(keys: [key], to: "Atelier", apply: true) == id)
        do { _ = try await store.add(keys: [key, "Inconnue"], to: "Autre", apply: true); Issue.record("clé inconnue acceptée") }
        catch {}
        let counts = try await db.pool.read { conn in
            (try BookCollection.fetchCount(conn), try CollectionItem.fetchCount(conn), try Document.fetchCount(conn), try Annotation.fetchCount(conn))
        }
        #expect(counts.0 == 1 && counts.1 == 1 && counts.2 == 1 && counts.3 == 1)
    }

    @Test("Manuscrit sans texte : genre, réserve et responsables distincts survivent à la publication")
    func publication() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (edition, doc) = try await seed(db)
        let store = CatalogStore(db: db)
        try await store.setPresentation(DocumentPresentation(documentId: doc, kind: .manuscrit, label: "Fac-similé", note: "Feuillet 3 manquant", preferred: true))
        try await store.updatePresentation(documentId: doc, label: "Image conseillée")
        let preserved = try await db.pool.read { try DocumentPresentation.fetchOne($0, key: doc) }
        #expect(preserved?.kind == .manuscrit && preserved?.preferred == true && preserved?.note == "Feuillet 3 manquant")
        try await store.setEditionCreators(["Bob Exemple"], role: .editor, editionId: edition)
        let key = try await db.pool.read { try String.fetchOne($0, sql: "SELECT key FROM edition_key")! }
        let id = try #require(try await CollectionStore(db: db).add(keys: [key], to: "Atelier", apply: true))
        // Un exemplaire sans qualification, classé heuristiquement livre, arrive avant le manuscrit.
        try await db.pool.write { conn in
            try Document(editionId: edition, filePath: "/fixture/A.pdf", originalFileName: "A.pdf", fileSize: 1, contentHash: String(repeating: "b", count: 64), format: .pdf).insert(conn)
            let hidden = BookCollection(name: "_NON_BIBLIO")
            try hidden.insert(conn)
            let child = BookCollection(name: "Séminaire", parentId: hidden.id)
            try child.insert(conn)
            try CollectionItem(collectionId: child.id, workId: Edition.fetchOne(conn, key: edition)!.workId).insert(conn)
            try CollectionItem(collectionId: hidden.id, workId: Edition.fetchOne(conn, key: edition)!.workId).insert(conn)
        }
        // Un rayonnage physique ne doit pas devenir un espace de travail.
        try await db.pool.write { conn in
            let shelf = BookCollection(name: "Dossier", sourceFolderPath: "/fixture/Dossier")
            try shelf.insert(conn)
            let work = try Edition.fetchOne(conn, key: edition)!.workId
            try CollectionItem(collectionId: shelf.id, workId: work).insert(conn)
        }
        #expect(try await DocumentKind.kinds(in: db)[doc] == .manuscrit)
        let catalogue = try await CatalogPublisher(db: db).build(root: "/fixture", rules: PublicationRules(excludedFolders: ["_NON_BIBLIO"])).0
        let entry = try #require(catalogue.editions.first)
        #expect(entry.kind == "manuscrit")
        #expect(entry.authors == ["Alice Exemple"])
        #expect(entry.collectionIds == [id.uuidString])
        #expect(catalogue.collections?.map(\.name) == ["Atelier"])
        #expect(entry.files.first { $0.preferred == true } != nil)
        #expect(entry.files.first { $0.preferred == true }?.note == "Feuillet 3 manquant")
        let csl = BibliographyExport.csl(entry)
        #expect(csl["type"] as? String == "manuscript")
        #expect((csl["author"] as? [[String: String]])?.count == 1)
        #expect((csl["editor"] as? [[String: String]])?.count == 1)
        #expect(BibliographyExport.bibtex(entry).hasPrefix("@unpublished{"))
        #expect(BibliographyExport.bibtex(entry).contains("editor = {Exemple, Bob}"))
    }
}
