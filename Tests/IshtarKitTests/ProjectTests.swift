import Testing
import Foundation
import GRDB
@testable import IshtarCatalog

@Suite("Projets et Encres (Lot B)")
struct ProjectTests {
    private func makeDatabase() async throws -> CatalogDatabase {
        try CatalogDatabase(inMemory: ())
    }

    private func seedDocuments(db: CatalogDatabase) async throws -> (UUID, UUID) {
        let work = Work(title: "W")
        let ed = Edition(workId: work.id)
        let doc1 = Document(editionId: ed.id, filePath: "/1", originalFileName: "1", fileSize: 1, format: .pdf)
        let doc2 = Document(editionId: ed.id, filePath: "/2", originalFileName: "2", fileSize: 1, format: .pdf)
        try await db.pool.write { conn in
            try work.insert(conn)
            try ed.insert(conn)
            try doc1.insert(conn)
            try doc2.insert(conn)
        }
        return (doc1.id, doc2.id)
    }

    @Test("Cycle de vie d'un projet : création, renommage, suppression")
    func projectLifecycle() async throws {
        let db = try await makeDatabase()
        let store = ProjectStore(db: db)

        let p1 = try await store.add(Project(name: "P1"))
        #expect(try await store.projects().count == 1)

        try await store.rename(id: p1.id, newName: "Renommé")
        let projects = try await store.projects()
        #expect(projects.first?.name == "Renommé")

        try await store.remove(id: p1.id)
        #expect(try await store.projects().isEmpty)
    }

    @Test("Un document dans un projet : ajout, unicité, retrait")
    func projectItems() async throws {
        let db = try await makeDatabase()
        let store = ProjectStore(db: db)
        let (doc1, _) = try await seedDocuments(db: db)

        let p1 = try await store.add(Project(name: "P1"))
        
        // Ajout
        try await store.addDocument(doc1, toProjectId: p1.id)
        
        let count = try await db.pool.read { try ProjectItem.fetchCount($0) }
        #expect(count == 1)
        
        // Unicité : un deuxième ajout lève une erreur (contrainte UNIQUE)
        await #expect(throws: DatabaseError.self) {
            try await store.addDocument(doc1, toProjectId: p1.id)
        }
        
        // Retrait
        try await store.removeDocument(doc1, fromProjectId: p1.id)
        #expect(try await db.pool.read { try ProjectItem.fetchCount($0) } == 0)
    }

    @Test("La suppression d'un projet remet à nul les projectId de ses annotations et encres")
    func projectDeletionPreservesAnnotationsAndLinks() async throws {
        let db = try await makeDatabase()
        let projectStore = ProjectStore(db: db)
        let linkStore = LinkStore(db: db)
        let (doc1, _) = try await seedDocuments(db: db)

        let p1 = try await projectStore.add(Project(name: "P1"))
        
        // On crée deux annotations avec ce projectId
        let a1 = Annotation(documentId: doc1, quote: "1", projectId: p1.id)
        let a2 = Annotation(documentId: doc1, quote: "2", projectId: p1.id)
        try await db.pool.write {
            try a1.insert($0)
            try a2.insert($0)
        }
        
        // On crée une encre avec ce projectId
        let link = try await linkStore.add(Link(kind: "relation", projectId: p1.id, sourceAnnotationId: a1.id, targetAnnotationId: a2.id))
        
        // On supprime le projet
        try await projectStore.remove(id: p1.id)
        
        // Les annotations existent toujours, mais projectId est nil
        let annotations = try await db.pool.read { try Annotation.fetchAll($0) }
        #expect(annotations.count == 2)
        #expect(annotations[0].projectId == nil)
        #expect(annotations[1].projectId == nil)
        
        // L'encre existe toujours, mais projectId est nil
        let links = try await db.pool.read { try Link.fetchAll($0) }
        #expect(links.count == 1)
        #expect(links[0].projectId == nil)
    }

    @Test("Cycle de vie d'une encre")
    func linkLifecycle() async throws {
        let db = try await makeDatabase()
        let linkStore = LinkStore(db: db)
        let (doc1, doc2) = try await seedDocuments(db: db)

        let a1 = Annotation(documentId: doc1, quote: "1")
        let a2 = Annotation(documentId: doc2, quote: "2")
        try await db.pool.write {
            try a1.insert($0)
            try a2.insert($0)
        }
        
        // Ajouter une encre
        let link = try await linkStore.add(Link(kind: "contraste", sourceAnnotationId: a1.id, targetAnnotationId: a2.id))
        
        // Lister par annotation
        #expect(try await linkStore.links(forAnnotationId: a1.id).count == 1)
        #expect(try await linkStore.links(forAnnotationId: a2.id).count == 1)
        #expect(try await linkStore.links(forAnnotationId: UUID()).isEmpty)
        
        // Lister par document
        #expect(try await linkStore.links(forDocumentId: doc1).count == 1)
        #expect(try await linkStore.links(forDocumentId: doc2).count == 1)
        
        // Supprimer l'encre
        try await linkStore.remove(id: link.id)
        #expect(try await linkStore.links(forAnnotationId: a1.id).isEmpty)
    }
}
