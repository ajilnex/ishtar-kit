import Testing
import Foundation
import GRDB
@testable import IshtarCatalog
@testable import IshtarSearch

@Suite("Catalogue publié (lot F3)")
struct PublisherTests {
    private let root = "/lib/Bibliothèque"

    /// Une œuvre, son édition, un document ; renvoie l'id d'édition.
    @discardableResult
    private func add(_ db: CatalogDatabase, title: String, author: String = "Adorno", year: String = "1951",
                     path: String, hash: String?, missing: Bool = false,
                     status: CurationStatus = .recognized) async throws -> UUID {
        try await db.pool.write { conn in
            let work = Work(title: title)
            try work.insert(conn)
            let creator = Creator(name: author)
            try creator.insert(conn)
            try WorkCreator(workId: work.id, creatorId: creator.id).insert(conn)
            let edition = Edition(workId: work.id, year: year)
            try edition.insert(conn)
            try Document(editionId: edition.id, filePath: path,
                         originalFileName: (path as NSString).lastPathComponent,
                         fileSize: 10, contentHash: hash, format: .pdf,
                         isMissing: missing, curationStatus: status).insert(conn)
            try EditionKey.assignMissing(conn)
            return edition.id
        }
    }

    private func seeded() async throws -> CatalogDatabase {
        let db = try CatalogDatabase(inMemory: ())
        try await add(db, title: "Minima moralia", path: "\(root)/Adorno_1951_Minima.pdf", hash: "aaa")
        try await add(db, title: "Journal intime", path: "\(root)/_NON_BIBLIO/journal.pdf", hash: "bbb")
        try await add(db, title: "TRIER facture", path: "\(root)/Sellars_ND_TRIER-facture.pdf", hash: "ccc")
        try await add(db, title: "Disparu", path: "\(root)/Disparu.pdf", hash: "ddd", missing: true)
        try await add(db, title: "Ignoré", path: "\(root)/Ignore.pdf", hash: "eee", status: .ignored)
        try await add(db, title: "Ailleurs", path: "/autre/Ailleurs.pdf", hash: "fff")
        try await add(db, title: "Minima moralia bis", path: "\(root)/copie/Adorno_copie.pdf", hash: "aaa")
        try await add(db, title: "Sans empreinte", path: "\(root)/Sans.pdf", hash: nil)
        return db
    }

    private let rules = PublicationRules(excludedFolders: ["_NON_BIBLIO/"], excludedTitlePrefixes: ["TRIER"])

    @Test("Seuls les documents présents, hors exclusions, sous la racine, une fois par empreinte")
    func filtering() async throws {
        let (catalogue, report) = try await CatalogPublisher(db: try await seeded())
            .build(root: root + "/", rules: rules)

        #expect(catalogue.editions.map(\.title) == ["Minima moralia"])
        let edition = try #require(catalogue.editions.first)
        #expect(edition.key == "Adorno1951Minima")
        #expect(edition.files == [PublishedFile(sha256: "aaa", path: "Adorno_1951_Minima.pdf", format: "pdf", size: 10)])
        #expect(catalogue.library == "Bibliothèque")
        #expect(report.excludedByRule == 2)
        #expect(report.excludedMissingOrIgnored == 2)
    }

    @Test("Publication sur disque : manifeste, couvertures, base réduite sans rien de privé")
    func writing() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ishtar-publish-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let covers = tmp.appendingPathComponent("thumbs")
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try Data([1]).write(to: covers.appendingPathComponent("aaa.png"))
        try Data([2]).write(to: covers.appendingPathComponent("bbb.png"))
        let out = tmp.appendingPathComponent("out")

        // Base sur disque : VACUUM INTO n'existe pas pour une base en mémoire.
        let db = try CatalogDatabase(at: tmp.appendingPathComponent("catalog.sqlite"))
        try await add(db, title: "Minima moralia", path: "\(root)/Adorno_1951_Minima.pdf", hash: "aaa")
        try await add(db, title: "Journal intime", path: "\(root)/_NON_BIBLIO/journal.pdf", hash: "bbb")

        let report = try await CatalogPublisher(db: db)
            .publish(root: root, rules: rules, to: out, coversFolder: covers)
        #expect(report.editions == 1)
        #expect(report.covers == 1)

        #expect(fm.fileExists(atPath: out.appendingPathComponent("covers/aaa.png").path))
        #expect(!fm.fileExists(atPath: out.appendingPathComponent("covers/bbb.png").path))

        let json = try Data(contentsOf: out.appendingPathComponent("catalogue.json"))
        #expect(!String(decoding: json, as: UTF8.self).contains("NON_BIBLIO"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(PublishedCatalogue.self, from: json).editions.count == 1)

        let snapshot = try DatabaseQueue(path: out.appendingPathComponent("catalog.sqlite").path)
        let paths = try await snapshot.read { try String.fetchAll($0, sql: "SELECT filePath FROM document") }
        #expect(paths == ["\(root)/Adorno_1951_Minima.pdf"])

        // Republier est idempotent et remplace proprement.
        let again = try await CatalogPublisher(db: db)
            .publish(root: root, rules: rules, to: out, coversFolder: covers)
        #expect(again == report)
    }
}
