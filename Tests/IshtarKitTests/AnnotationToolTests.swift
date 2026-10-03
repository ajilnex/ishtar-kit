// Propre à macOS (cadres d'Apple ou démon) : hors de la suite Linux (WP-34).
#if canImport(Darwin)
import Testing
import Foundation
@testable import IshtarCatalog
@testable import IshtarDaemon

@Suite("Recherche dans les annotations (Démon)")
struct AnnotationToolTests {
    private func makeLibrary() async throws -> (CatalogDatabase, UUID) {
        let db = try CatalogDatabase(inMemory: ())
        let work = Work(title: "Critique de la raison pure")
        let edition = Edition(workId: work.id)
        let document = Document(editionId: edition.id, filePath: "/tmp/k.pdf",
                                originalFileName: "k.pdf", fileSize: 1, format: .pdf)
        
        let creator = Creator(name: "Kant")
        let wc = WorkCreator(workId: work.id, creatorId: creator.id)

        try await db.pool.write { conn in
            try work.insert(conn)
            try edition.insert(conn)
            try document.insert(conn)
            try creator.insert(conn)
            try wc.insert(conn)
        }
        return (db, document.id)
    }

    @Test("La fonction de tri (pure) est insensible à la casse/accent et priorise les notes")
    func pureFilterAndSort() throws {
        let dummyDoc = UUID()
        let c1 = Annotation(documentId: dummyDoc, quote: "Le mot clé est ici", note: "Rien", dateModified: Date(timeIntervalSince1970: 1))
        let c2 = Annotation(documentId: dummyDoc, quote: "Autre", note: "Le mot CLE est là", dateModified: Date(timeIntervalSince1970: 2))
        let c3 = Annotation(documentId: dummyDoc, quote: "clé", note: "Aussi clE", dateModified: Date(timeIntervalSince1970: 3))
        let c4 = Annotation(documentId: dummyDoc, quote: "Rien du tout", note: "Rien du tout", dateModified: Date(timeIntervalSince1970: 4))

        let results = AnnotationStore.search(query: "clé", in: [c1, c2, c3, c4])
        
        #expect(results.count == 3) // c4 ignoré
        // La note prime sur la citation.
        // c3 (note match) date=3
        // c2 (note match) date=2
        // c1 (quote match seulement) date=1
        #expect(results[0].dateModified.timeIntervalSince1970 == 3)
        #expect(results[1].dateModified.timeIntervalSince1970 == 2)
        #expect(results[2].dateModified.timeIntervalSince1970 == 1)
    }

    @Test("Recherche d'annotation sur un document sans édition (C1)")
    func searchAnnotationWithoutEdition() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let docWithoutEdition = Document(filePath: "/tmp/doc_orphelin.pdf", originalFileName: "doc_orphelin.pdf", fileSize: 1, format: .pdf)
        try await db.pool.write { try docWithoutEdition.insert($0) }
        
        let store = AnnotationStore(db: db)
        _ = try await store.add(Annotation(documentId: docWithoutEdition.id, quote: "citation orpheline", note: "test C1"))
        
        let results = try await store.search(query: "orpheline")
        #expect(results.count == 1)
        #expect(results[0].workTitle == "doc_orphelin.pdf")
        #expect(results[0].authors.isEmpty)
    }

    @Test("L'outil gère correctement un CFI sans page (C2)")
    func toolboxHandlesCFIWithoutPage() async throws {
        let (db, docId) = try await makeLibrary()
        let store = AnnotationStore(db: db)
        
        _ = try await store.add(Annotation(
            documentId: docId, pageNumber: nil, cfi: "/4/2/12", quote: "une phrase epub", note: "une note epub"
        ))
        
        let toolbox = DaemonToolbox(db: db, semantic: nil)
        let (res, _) = await toolbox.execute(name: "search_annotations", argumentsJSON: #"{"query":"epub"}"#)
        
        #expect(res.contains("/4/2/12"))
        #expect(!res.contains("page absente"))
        #expect(res.contains("- document_id: \(docId)"))
        #expect(res.contains("passage surligné : une phrase epub"))
    }

    @Test("Recherche en base, filtre et étiquettes d'outil")
    func databaseSearchAndToolbox() async throws {
        let (db, docId) = try await makeLibrary()
        let store = AnnotationStore(db: db)

        _ = try await store.add(Annotation(
            documentId: docId, pageNumber: 2, quote: "intuitions sans concepts",
            note: "à relier avec Platon", dateModified: Date(timeIntervalSince1970: 100)
        ))
        
        let toolbox = DaemonToolbox(db: db, semantic: nil)
        
        let (res, cmd) = await toolbox.execute(name: "search_annotations", argumentsJSON: #"{"query":"platon"}"#)
        
        #expect(res.contains("Kant")) // Author
        #expect(res.contains("Critique de la raison pure")) // Work title
        #expect(res.contains("p. 2")) // Page (exploitable pour open_document)
        #expect(res.contains("passage surligné : intuitions sans concepts")) // Etiquette citation
        #expect(res.contains("note du chercheur : à relier avec Platon")) // Etiquette note
        #expect(cmd == nil) // search_annotations n'émet pas de UICommand
        
        // Test filtre
        let (res2, _) = await toolbox.execute(name: "search_annotations", argumentsJSON: #"{"query":"platon", "document_id":"\#(docId.uuidString)"}"#)
        #expect(res2.contains("Kant"))
        
        let (res3, _) = await toolbox.execute(name: "search_annotations", argumentsJSON: #"{"query":"platon", "document_id":"\#(UUID().uuidString)"}"#)
        #expect(res3.contains("Aucune annotation trouvée"))
        
        // Test cas vide
        let (res4, _) = await toolbox.execute(name: "search_annotations", argumentsJSON: #"{"query":"introuvable"}"#)
        #expect(res4.contains("Aucune annotation trouvée"))
    }
}
#endif
