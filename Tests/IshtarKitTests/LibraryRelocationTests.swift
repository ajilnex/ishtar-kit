import Testing
import Foundation
import GRDB
@testable import IshtarCatalog

@Suite("Déplacement d'une bibliothèque (lot F)")
struct LibraryRelocationTests {
    private func seed(_ paths: [String], root: String) async throws -> CatalogDatabase {
        let db = try CatalogDatabase(inMemory: ())
        try await db.pool.write { conn in
            try SourceFolder(path: root).insert(conn)
            for path in paths {
                let work = Work(title: path)
                let edition = Edition(workId: work.id)
                try work.insert(conn)
                try edition.insert(conn)
                try Document(editionId: edition.id, filePath: path, originalFileName: path,
                             fileSize: 1, format: .pdf).insert(conn)
            }
        }
        return db
    }

    private func paths(_ db: CatalogDatabase) async throws -> [String] {
        try await db.pool.read { try String.fetchAll($0, sql: "SELECT filePath FROM document ORDER BY filePath") }
    }

    @Test("Les documents et le dossier source suivent la nouvelle racine")
    func relocatesPrefix() async throws {
        let db = try await seed(["/a/Ma bibliothèque/Kant_1781_Critique.pdf",
                                 "/a/Ma bibliothèque/Phéno/Hegel_1807_Phenomenologie.epub",
                                 "/a/Autre/Intrus.pdf"],
                                root: "/a/Ma bibliothèque")
        let moved = try await CatalogStore(db: db)
            .relocateLibrary(from: "/a/Ma bibliothèque/", to: "/b/Rayonnages/Ma bibliothèque")

        #expect(moved == 2)
        #expect(try await paths(db) == ["/a/Autre/Intrus.pdf",
                                        "/b/Rayonnages/Ma bibliothèque/Kant_1781_Critique.pdf",
                                        "/b/Rayonnages/Ma bibliothèque/Phéno/Hegel_1807_Phenomenologie.epub"])
        #expect(try await CatalogStore(db: db).sourceFolderPaths() == ["/b/Rayonnages/Ma bibliothèque"])
    }

    @Test("« _ » et « % » ne sont pas des jokers ; un voisin au nom proche n'est pas emporté")
    func noWildcardOverreach() async throws {
        let db = try await seed(["/x/Lib_1/A.pdf", "/x/LibX1/B.pdf", "/x/Lib_10/C.pdf"], root: "/x/Lib_1")
        let moved = try await CatalogStore(db: db).relocateLibrary(from: "/x/Lib_1", to: "/y/Lib")
        #expect(moved == 1)
        #expect(try await paths(db) == ["/x/LibX1/B.pdf", "/x/Lib_10/C.pdf", "/y/Lib/A.pdf"])
    }

    @Test("Une racine enregistrée en NFD est retrouvée depuis un chemin NFC")
    func unicodeNormalization() async throws {
        let nfd = "/a/Bibliothe\u{0300}que"
        let nfc = "/a/Bibliothèque"
        let db = try await seed([nfd + "/Doc.pdf"], root: nfd)
        let moved = try await CatalogStore(db: db).relocateLibrary(from: nfc, to: "/b/Neuve")
        #expect(moved == 1)
        #expect(try await paths(db) == ["/b/Neuve/Doc.pdf"])
    }

    @Test("Refus de fusionner avec une destination déjà peuplée ; rien n'est modifié")
    func refusesOccupiedDestination() async throws {
        let db = try await seed(["/a/L/A.pdf", "/b/L/B.pdf"], root: "/a/L")
        await #expect(throws: LibraryRelocationError.destinationOccupied(count: 1)) {
            try await CatalogStore(db: db).relocateLibrary(from: "/a/L", to: "/b/L")
        }
        #expect(try await paths(db) == ["/a/L/A.pdf", "/b/L/B.pdf"])
    }

    @Test("Déplacer vers le même endroit est refusé")
    func refusesSamePath() async throws {
        let db = try await seed(["/a/L/A.pdf"], root: "/a/L")
        await #expect(throws: LibraryRelocationError.samePath) {
            try await CatalogStore(db: db).relocateLibrary(from: "/a/L/", to: "/a/L")
        }
    }
}
