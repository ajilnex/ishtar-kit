import Testing
import Foundation
import GRDB
@testable import IshtarCatalog
@testable import IshtarIngest

@Suite("Témoins d'auteurs au renommage")
struct RenamingGuardTests {
    @Test("Les formes inversées et les listes désignent les mêmes coauteurs")
    func coauthors() {
        let authors = ["Alice Norel", "Benoît Varet"]
        for source in ["Norel, Alice, Varet, Benoît", "Alice Norel, Benoît Varet",
                       "Varet, Benoît; Norel, Alice", "Norel & Varet", "Norel-Varet"] {
            #expect(RenamingGuard.authorsAgree(source, with: authors))
        }
        #expect(RenamingGuard.authorsAgree("Norel, Alice", with: ["Alice Norel"]))
        #expect(RenamingGuard.authorsAgree("Norel", with: authors))
        #expect(RenamingGuard.authorsAgree("Norel et al.", with: authors))
        #expect(!RenamingGuard.authorsAgree("Orbel et al.", with: authors))
    }

    @Test("Un auteur supplémentaire ou inconnu reste un conflit")
    func conflicts() {
        #expect(!RenamingGuard.authorsAgree("Norel, Alice, Varet, Benoît", with: ["Alice Norel"]))
        #expect(!RenamingGuard.authorsAgree("Norel; Orbel", with: ["Alice Norel", "Benoît Varet"]))
        #expect(!RenamingGuard.authorsAgree("Norel-Orbel", with: ["Alice Norel", "Benoît Varet"]))
        #expect(!RenamingGuard.authorsAgree("Varet", with: ["Alice Norel"]))
        #expect(!RenamingGuard.authorsAgree("Norel; Norel", with: ["Alice Norel"]))
        #expect(!RenamingGuard.authorsAgree("Norel;;Varet", with: ["Alice Norel", "Benoît Varet"]))
        #expect(!RenamingGuard.authorsAgree("Alice; Benoît", with: ["Alice Norel", "Benoît Varet"]))
    }

    @Test("L'éditeur doit être connu exactement et accompagné d'un auteur")
    func publisher() {
        #expect(RenamingGuard.authorsAgree("Alice Norel; Éditions Boréales", with: ["Alice Norel"], publisher: "Éditions Boréales"))
        #expect(!RenamingGuard.authorsAgree("Alice Norel; Éditions Boréales", with: ["Alice Norel"]))
        #expect(!RenamingGuard.authorsAgree("Alice Norel; Éditions Boréales", with: ["Alice Norel"], publisher: "Autres Éditions"))
        #expect(!RenamingGuard.authorsAgree("Orbel; Éditions Boréales", with: ["Alice Norel"], publisher: "Éditions Boréales"))
        #expect(!RenamingGuard.authorsAgree("Éditions Boréales; Éditions Boréales", with: ["Alice Norel"], publisher: "Éditions Boréales"))
    }

    @Test("Le plan transmet tous les auteurs même si l'étiquette abrège la liste")
    func catalogueWitnesses() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let work = Work(title: "Traité des formes", date: "2020", curationStatus: .recognized, confidence: .probable)
        let edition = Edition(workId: work.id, publisher: "Éditions Boréales", year: "2020", curationStatus: .recognized, confidence: .probable)
        let document = Document(editionId: edition.id, filePath: "/fixture/ancien.pdf", originalFileName: "ancien.pdf", fileSize: 1, format: .pdf, curationStatus: .recognized, confidence: .probable)
        try await db.pool.write { conn in
            try work.insert(conn); try edition.insert(conn); try document.insert(conn)
            for (position, name) in ["Alice Norel", "Benoît Varet", "Claire Orbel"].enumerated() {
                let creator = Creator(name: name)
                try creator.insert(conn)
                try conn.execute(sql: "INSERT INTO work_creator(workId, creatorId, role, position) VALUES (?, ?, 'author', ?)", arguments: [work.id, creator.id, position])
            }
        }
        let plan = try await CatalogStore(db: db).arrangement(root: "/fixture", excludedFolders: [])
        let entry = try #require(plan.first)
        #expect(entry.authors == ["Alice Norel", "Benoît Varet", "Claire Orbel"])
        #expect(entry.publisher == "Éditions Boréales")
        #expect(entry.to.contains("Norel et al."))
        #expect(RenamingGuard.authorsAgree("Norel, Alice, Varet, Benoît, Orbel, Claire", with: entry.authors, publisher: entry.publisher))
    }
}
