import Foundation
import Testing
import GRDB
@testable import IshtarCatalog
@testable import IshtarIngest

@Suite("Import Zotero")
struct ZoteroImportTests {
    
    private func createDummyZoteroDatabase(at url: URL) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE collections (collectionID INTEGER PRIMARY KEY, collectionName TEXT, parentCollectionID INTEGER);
                CREATE TABLE collectionItems (collectionID INTEGER, itemID INTEGER);
                CREATE TABLE items (itemID INTEGER PRIMARY KEY, key TEXT, itemTypeID INTEGER);
                CREATE TABLE itemAttachments (itemID INTEGER PRIMARY KEY, parentItemID INTEGER, path TEXT);
                
                INSERT INTO collections (collectionID, collectionName, parentCollectionID) VALUES (1, 'Parent Collection', NULL);
                INSERT INTO collections (collectionID, collectionName, parentCollectionID) VALUES (2, 'Child Collection', 1);
                INSERT INTO collections (collectionID, collectionName, parentCollectionID) VALUES (3, 'Empty Collection', NULL);
                
                INSERT INTO items (itemID, key, itemTypeID) VALUES (101, 'ITEM1', 1);
                INSERT INTO itemAttachments (itemID, parentItemID, path) VALUES (201, 101, 'storage:doc1.pdf');
                
                INSERT INTO items (itemID, key, itemTypeID) VALUES (102, 'ITEM2', 1);
                INSERT INTO itemAttachments (itemID, parentItemID, path) VALUES (202, 102, 'storage:missing.pdf');
                
                INSERT INTO items (itemID, key, itemTypeID) VALUES (103, 'ITEM3', 1);
                INSERT INTO itemAttachments (itemID, parentItemID, path) VALUES (203, 103, 'storage:doc-no-edition.pdf');
                
                INSERT INTO collectionItems (collectionID, itemID) VALUES (2, 101);
                INSERT INTO collectionItems (collectionID, itemID) VALUES (1, 102);
                INSERT INTO collectionItems (collectionID, itemID) VALUES (1, 103);
            """)
        }
    }
    
    @Test("Import d'une base Zotero avec arborescence et correspondances")
    func zoteroImport() async throws {
        let catalogURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: catalogURL) }
        
        let catalogDB = try CatalogDatabase(at: catalogURL)
        
        try await catalogDB.pool.write { db in
            let work = Work(id: UUID(), title: "Test Work")
            try work.insert(db)
            
            let edition = Edition(id: UUID(), workId: work.id, doi: nil)
            try edition.insert(db)
            let doc1 = Document(id: UUID(), editionId: edition.id, filePath: "doc1.pdf", originalFileName: "doc1.pdf", fileSize: 1024, format: .pdf)
            try doc1.insert(db)
            
            let doc2 = Document(id: UUID(), editionId: nil, filePath: "doc-no-edition.pdf", originalFileName: "doc-no-edition.pdf", fileSize: 1024, format: .pdf)
            try doc2.insert(db)
            
            let col = BookCollection(id: UUID(), name: "Existing Folder", sourceFolderPath: "/some/path")
            try col.insert(db)
        }
        
        let zoteroDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: zoteroDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: zoteroDir) }
        
        let zoteroDBURL = zoteroDir.appendingPathComponent("zotero.sqlite")
        try createDummyZoteroDatabase(at: zoteroDBURL)
        
        let importer = ZoteroImporter()
        
        // Dry run
        let reportDry = try await importer.importDatabase(at: zoteroDBURL, into: catalogDB, apply: false)
        #expect(reportDry.attachmentsFound == 3)
        #expect(reportDry.matchedAttachments == 2)
        #expect(reportDry.collectionsCreated == 2) // Parent and Child
        #expect(reportDry.itemsWithoutFile == 1) // missing.pdf
        #expect(reportDry.unclassifiableDocuments == 1) // doc-no-edition.pdf
        
        try await catalogDB.pool.read { db in
            let collections = try BookCollection.fetchAll(db)
            #expect(collections.count == 1) // Only the one with sourceFolderPath
        }
        
        // Apply run
        let reportApply = try await importer.importDatabase(at: zoteroDir, into: catalogDB, apply: true) // directory test
        #expect(reportApply.collectionsCreated == 2)
        
        try await catalogDB.pool.read { db in
            let collections = try BookCollection.fetchAll(db)
            #expect(collections.count == 3) // 1 existing + 2 Zotero
            
            let parent = collections.first { $0.name == "Parent Collection" }
            let child = collections.first { $0.name == "Child Collection" }
            #expect(parent != nil)
            #expect(child != nil)
            #expect(child?.parentId == parent?.id)
            
            let empty = collections.first { $0.name == "Empty Collection" }
            #expect(empty == nil) // should not be created
            
            let colItems = try CollectionItem.fetchAll(db)
            #expect(colItems.count == 1)
            #expect(colItems.first?.collectionId == child?.id)
        }
        
        // Idempotence test
        let reportSecond = try await importer.importDatabase(at: zoteroDBURL, into: catalogDB, apply: true)
        #expect(reportSecond.collectionsCreated == 0)
    }
}
