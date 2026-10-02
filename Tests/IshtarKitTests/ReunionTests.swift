import Testing
import Foundation
import GRDB
@testable import IshtarCatalog
@testable import IshtarIngest

@Suite("Réunir à la main un original et ses traductions")
struct ReunionTests {
    /// Une œuvre, son édition, sa clé ; rend (œuvre, édition).
    @discardableResult
    private func add(_ db: CatalogDatabase, title: String, date: String?, year: String, language: String,
                     key: String, confidence: Confidence, notes: String? = nil) async throws -> (UUID, UUID) {
        try await db.pool.write { conn in
            let work = Work(title: title, date: date, notes: notes, confidence: confidence)
            try work.insert(conn)
            let creator = Creator(name: "Michael Heinrich")
            try creator.insert(conn)
            try WorkCreator(workId: work.id, creatorId: creator.id).insert(conn)
            let edition = Edition(workId: work.id, year: year, language: language)
            try edition.insert(conn)
            try EditionKey(editionId: edition.id, key: key, origin: .stable).insert(conn)
            return (work.id, edition.id)
        }
    }

    @Test("L'original garde son œuvre ; la traduction y entre avec son titre ; les clés ne bougent pas")
    func reunion() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (original, de) = try await add(db, title: "Kritik der politischen Ökonomie. Eine Einführung", date: "2004",
                                           year: "2004", language: "de", key: "Heinrich2004Kritik", confidence: .high)
        let (traduction, en) = try await add(db, title: "An Introduction to the Three Volumes of Karl Marx's Capital", date: "2004",
                                             year: "2012", language: "en", key: "Heinrich2012Introduction", confidence: .high,
                                             notes: "Vérifié sur pièce.")
        let n = try await TranslationPass.reunir(keys: ["Heinrich2004Kritik", "Heinrich2012Introduction"],
                                                 preuve: "« Originally published as Kritik der politischen Ökonomie »",
                                                 date: "2026-10-02", in: db)
        #expect(n == 1)
        try await db.pool.read { conn in
            #expect(try Work.fetchOne(conn, key: traduction) == nil)
            let editions = try Edition.filter(Column("workId") == original).fetchAll(conn)
            #expect(Set(editions.map(\.id)) == [de, en])
            #expect(editions.first { $0.id == en }?.title == "An Introduction to the Three Volumes of Karl Marx's Capital")
            #expect(editions.first { $0.id == de }?.title == "Kritik der politischen Ökonomie. Eine Einführung")
            let work = try #require(try Work.fetchOne(conn, key: original))
            #expect(work.title == "Kritik der politischen Ökonomie. Eine Einführung")
            #expect(work.originalLanguage == "de")
            #expect(work.notes?.contains("Vérifié sur pièce.") == true)
            #expect(work.notes?.contains("Réunion sur pièce le 2026-10-02") == true)
            let keys = try String.fetchAll(conn, sql: "SELECT key FROM edition_key ORDER BY key")
            #expect(keys == ["Heinrich2004Kritik", "Heinrich2012Introduction"])
        }
    }

    @Test("Une clé inconnue ou une seule clé : refus, rien d'écrit")
    func refus() async throws {
        let db = try CatalogDatabase(inMemory: ())
        try await add(db, title: "Kritik", date: "2004", year: "2004", language: "de", key: "Heinrich2004Kritik", confidence: .high)
        await #expect(throws: TranslationPass.ReunionError.self) {
            try await TranslationPass.reunir(keys: ["Heinrich2004Kritik", "Absent1999Rien"], preuve: "—", date: "2026-10-02", in: db)
        }
        await #expect(throws: TranslationPass.ReunionError.self) {
            try await TranslationPass.reunir(keys: ["Heinrich2004Kritik"], preuve: "—", date: "2026-10-02", in: db)
        }
        let works = try await db.pool.read { try Work.fetchCount($0) }
        #expect(works == 1)
    }
}
