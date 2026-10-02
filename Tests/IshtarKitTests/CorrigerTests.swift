import Testing
import Foundation
import GRDB
@testable import IshtarCatalog

@Suite("Une correction de machine reste « probable »")
struct CorrigerTests {
    @Test("La fiche corrigée revient à probable ; ce qui n'était pas haut ne bouge pas")
    func probable() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (work, edition, document, autre) = try await db.pool.write { conn in
            let work = Work(title: "Facts and the Function of Truth", confidence: .low)
            try work.insert(conn)
            let edition = Edition(workId: work.id, year: "1988", language: "en")
            try edition.insert(conn)
            let document = Document(editionId: edition.id, filePath: "/lib/Price.pdf", originalFileName: "FFT-FullText.pdf",
                                    fileSize: 10, contentHash: "aaa", format: .pdf, curationStatus: .recognized)
            try document.insert(conn)
            let autre = Work(title: "Autre", confidence: .low)
            try autre.insert(conn)
            return (work.id, edition.id, document.id, autre.id)
        }
        let store = CatalogStore(db: db)
        try await store.applyUserEdit(workId: work, editionId: edition, documentId: document,
                                      edit: RecordEdit(title: "Facts and the Function of Truth", authors: ["Huw Price"], year: "1988",
                                                       publisher: "Basil Blackwell", language: "en", isbn13: nil))
        let avant = try await db.pool.read { try Work.fetchOne($0, key: work)?.confidence }
        #expect(avant == .high)
        try await store.lowerToProbable(workId: work, editionId: edition, documentId: document)
        let apres = try await db.pool.read { conn in
            (try Work.fetchOne(conn, key: work)?.confidence, try Edition.fetchOne(conn, key: edition)?.confidence,
             try Document.fetchOne(conn, key: document)?.confidence, try Work.fetchOne(conn, key: autre)?.confidence)
        }
        #expect(apres.0 == .probable)
        #expect(apres.1 == .probable)
        #expect(apres.2 == .probable)
        #expect(apres.3 == .low)
    }
}
