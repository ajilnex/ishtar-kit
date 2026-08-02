import Foundation
import GRDB
import IshtarCatalog

public struct ZoteroCollectionRow: FetchableRecord, Decodable, Sendable {
    public let collectionID: Int
    public let collectionName: String
    public let parentCollectionID: Int?
}

public struct ZoteroCollectionItemRow: FetchableRecord, Decodable, Sendable {
    public let collectionID: Int
    public let itemID: Int
}

public struct ZoteroItemRow: FetchableRecord, Decodable, Sendable {
    public let itemID: Int
    public let key: String
    public let itemTypeID: Int
}

public struct ZoteroItemAttachmentRow: FetchableRecord, Decodable, Sendable {
    public let itemID: Int
    public let parentItemID: Int?
    public let path: String?
}

public struct ZoteroImportReport: Sendable {
    public let itemsRead: Int
    public let attachmentsFound: Int
    public let matchedAttachments: Int
    public let collectionsCreated: Int
    public let itemsWithoutFile: Int
    public let unclassifiableDocuments: Int
    public let skippedCollections: Int
    public let matchReasons: [String: Int]
}

public struct ZoteroImporter: Sendable {
    
    public init() {}
    
    public func importDatabase(at sourceURL: URL, into catalogDB: CatalogDatabase, apply: Bool) async throws -> ZoteroImportReport {
        var sqliteURL = sourceURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue {
            sqliteURL = sourceURL.appendingPathComponent("zotero.sqlite")
        }
        
        guard FileManager.default.fileExists(atPath: sqliteURL.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let tempDB = tempDir.appendingPathComponent("zotero.sqlite")
        try FileManager.default.copyItem(at: sqliteURL, to: tempDB)
        
        let walURL = sqliteURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
        let tempWal = tempDir.appendingPathComponent("zotero.sqlite-wal")
        if FileManager.default.fileExists(atPath: walURL.path) {
            try FileManager.default.copyItem(at: walURL, to: tempWal)
        }
        let shmURL = sqliteURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
        let tempShm = tempDir.appendingPathComponent("zotero.sqlite-shm")
        if FileManager.default.fileExists(atPath: shmURL.path) {
            try FileManager.default.copyItem(at: shmURL, to: tempShm)
        }
        
        let zoteroPool = try DatabasePool(path: tempDB.path)
        return try await doImport(zoteroPool: zoteroPool, catalogDB: catalogDB, apply: apply)
    }
    
    private func doImport(zoteroPool: DatabasePool, catalogDB: CatalogDatabase, apply: Bool) async throws -> ZoteroImportReport {
        let (zCollections, zCollectionItems, zItems, zAttachments) = try await zoteroPool.read { db -> ([ZoteroCollectionRow], [ZoteroCollectionItemRow], [ZoteroItemRow], [ZoteroItemAttachmentRow]) in
            let cols = try ZoteroCollectionRow.fetchAll(db, sql: "SELECT collectionID, collectionName, parentCollectionID FROM collections")
            let colItems = try ZoteroCollectionItemRow.fetchAll(db, sql: "SELECT collectionID, itemID FROM collectionItems")
            let items = try ZoteroItemRow.fetchAll(db, sql: "SELECT itemID, key, itemTypeID FROM items")
            let attachments = try ZoteroItemAttachmentRow.fetchAll(db, sql: "SELECT itemID, parentItemID, path FROM itemAttachments")
            return (cols, colItems, items, attachments)
        }
        
        let matcher = DocumentMatcher()
        
        return try await catalogDB.pool.write { db in
            let documents = try Document.fetchAll(db)
            let editions = try Edition.fetchAll(db)
            let works = try Work.fetchAll(db)
            
            var attachmentsFound = 0
            var matchedAttachments = 0
            var unclassifiableDocuments = 0
            var collectionsCreated = 0
            var matchReasons: [String: Int] = [:]
            
            var itemToDocument: [Int: Document] = [:]
            
            for attachment in zAttachments {
                guard let path = attachment.path else { continue }
                
                var fileName: String? = nil
                if path.hasPrefix("storage:") {
                    fileName = String(path.dropFirst("storage:".count))
                } else {
                    fileName = URL(fileURLWithPath: path).lastPathComponent
                }
                
                guard let fName = fileName else { continue }
                attachmentsFound += 1
                
                let query = MatchQuery(fileNames: [fName])
                let match = matcher.match(query: query, documents: documents, editions: editions, works: works, in: db)
                
                if let doc = match.document {
                    matchedAttachments += 1
                    let targetItemID = attachment.parentItemID ?? attachment.itemID
                    itemToDocument[targetItemID] = doc
                    
                    let reason: String
                    switch match.signal {
                    case .strong(let r): reason = r
                    case .weak(let r): reason = r
                    case .none: reason = "none"
                    }
                    matchReasons[reason, default: 0] += 1
                }
            }
            
            let itemsWithoutFile = zItems.count - itemToDocument.count
            
            var ishtarCollections = try BookCollection.fetchAll(db)
            var zoteroIdToIshtarId: [Int: UUID] = [:]
            var skippedCollections = 0
            
            func hasMatchedItems(_ cid: Int) -> Bool {
                let itemIds = zCollectionItems.filter({ $0.collectionID == cid }).map { $0.itemID }
                if itemIds.contains(where: { itemToDocument[$0] != nil }) { return true }
                let children = zCollections.filter({ $0.parentCollectionID == cid })
                return children.contains(where: { hasMatchedItems($0.collectionID) })
            }
            
            func processCollection(_ zCol: ZoteroCollectionRow) {
                if zoteroIdToIshtarId[zCol.collectionID] != nil { return }
                
                var parentIshtarId: UUID? = nil
                if let parentZoteroId = zCol.parentCollectionID {
                    if zoteroIdToIshtarId[parentZoteroId] == nil {
                        if let parent = zCollections.first(where: { $0.collectionID == parentZoteroId }) {
                            processCollection(parent)
                        }
                    }
                    parentIshtarId = zoteroIdToIshtarId[parentZoteroId]
                }
                
                if let existing = ishtarCollections.first(where: { $0.name == zCol.collectionName && $0.parentId == parentIshtarId && $0.sourceFolderPath == nil }) {
                    zoteroIdToIshtarId[zCol.collectionID] = existing.id
                } else if ishtarCollections.contains(where: { $0.name == zCol.collectionName && $0.parentId == parentIshtarId && $0.sourceFolderPath != nil }) {
                    // Do NOT touch collections with sourceFolderPath
                    skippedCollections += 1
                } else {
                    if hasMatchedItems(zCol.collectionID) {
                        let newId = UUID()
                        if apply {
                            let newCol = BookCollection(id: newId, name: zCol.collectionName, parentId: parentIshtarId, sourceFolderPath: nil)
                            try? newCol.insert(db)
                            ishtarCollections.append(newCol)
                        }
                        zoteroIdToIshtarId[zCol.collectionID] = newId
                        collectionsCreated += 1
                    }
                }
            }
            
            for zCol in zCollections {
                processCollection(zCol)
            }
            
            var existingCollectionItems = try CollectionItem.fetchAll(db)
            
            for zColItem in zCollectionItems {
                guard let ishtarColId = zoteroIdToIshtarId[zColItem.collectionID] else { continue }
                guard let doc = itemToDocument[zColItem.itemID] else { continue }
                
                guard let editionId = doc.editionId else {
                    unclassifiableDocuments += 1
                    continue
                }
                guard let edition = editions.first(where: { $0.id == editionId }) else { continue }
                
                let workId = edition.workId
                
                let existing = existingCollectionItems.contains(where: { $0.collectionId == ishtarColId && $0.workId == workId })
                if !existing {
                    if apply {
                        let newColItem = CollectionItem(collectionId: ishtarColId, workId: workId)
                        try? newColItem.insert(db)
                        existingCollectionItems.append(newColItem)
                    }
                }
            }
            
            return ZoteroImportReport(
                itemsRead: zItems.count,
                attachmentsFound: attachmentsFound,
                matchedAttachments: matchedAttachments,
                collectionsCreated: collectionsCreated,
                itemsWithoutFile: itemsWithoutFile,
                unclassifiableDocuments: unclassifiableDocuments,
                skippedCollections: skippedCollections,
                matchReasons: matchReasons
            )
        }
    }
}
