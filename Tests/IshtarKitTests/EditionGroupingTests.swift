import Testing
import Foundation
import GRDB
@testable import IshtarCatalog

@Suite("Regroupement des éditions")
struct EditionGroupingTests {
    /// Une œuvre, son édition, un document ; rend l'id d'édition.
    @discardableResult
    private func add(_ db: CatalogDatabase, title: String, author: String?, year: String?, file: String) async throws -> UUID {
        try await db.pool.write { conn in
            let work = Work(title: title); try work.insert(conn)
            if let author {
                let c = try Creator.filter(Column("name") == author).fetchOne(conn) ?? { let c = Creator(name: author); try c.insert(conn); return c }()
                try WorkCreator(workId: work.id, creatorId: c.id).insert(conn)
            }
            let e = Edition(workId: work.id, year: year); try e.insert(conn)
            try Document(editionId: e.id, filePath: "/lib/\(file)", originalFileName: file, fileSize: 1, format: .pdf).insert(conn)
            try EditionKey.assignMissing(conn)
            return e.id
        }
    }

    @Test("Même livre en deux fichiers : une fiche, la clé nue, deux documents")
    func sameBook() async throws {
        let db = try CatalogDatabase(inMemory: ())
        try await add(db, title: "Tout s'effondre", author: "Chinua Achebe", year: "1958", file: "a.epub")
        try await add(db, title: "Tout seffondre", author: "Achebe", year: "1958", file: "a.pdf")
        try await add(db, title: "Tout s'effondre", author: "Achebe", year: "2013", file: "autre-edition.pdf")
        try await add(db, title: "Anna Karénine - Tome I", author: "Tolstoï", year: "1877", file: "t1.pdf")
        try await add(db, title: "Anna Karénine - Tome II", author: "Tolstoï", year: "1877", file: "t2.pdf")

        let groups = try await EditionGrouping.proposals(in: db)
        #expect(groups.count == 1, "année différente ou tome différent : pas le même livre")
        #expect(groups.first?.keptKey == "Achebe1958Tout")
        #expect(try await EditionGrouping.apply(groups, to: db) == 1)

        let (docs, keys) = try await db.pool.read { conn in
            (try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM document WHERE editionId = ?", arguments: [groups[0].keptEditionId]),
             try String.fetchAll(conn, sql: "SELECT key FROM edition_key ORDER BY key"))
        }
        #expect(docs == 2)
        #expect(!keys.contains("Achebe1958Tout-b"), "la clé absorbée disparaît")
        #expect(try await EditionGrouping.proposals(in: db).isEmpty, "rejouable")
    }
}
