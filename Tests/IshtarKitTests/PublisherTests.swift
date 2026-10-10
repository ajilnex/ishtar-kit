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
        #expect(catalogue.fonds == nil)
        let avecFonds = try await CatalogPublisher(db: try await seeded())
            .build(root: root, rules: rules, fonds: PublishedFonds(id: "aj", nom: "aj")).0
        #expect(avecFonds.fonds == PublishedFonds(id: "aj", nom: "aj"))
        #expect(report.excludedByRule == 2)
        #expect(report.excludedMissingOrIgnored == 2)
    }

    @Test("Un dossier privé l'est à toute profondeur ; un chemin ne vaut que depuis la racine")
    func nestedPrivateFolders() async throws {
        let db = try CatalogDatabase(inMemory: ())
        try await add(db, title: "Minima moralia", path: "\(root)/Adorno_1951_Minima.pdf", hash: "aaa")
        try await add(db, title: "Bibliographie de séminaire", path: "\(root)/Wagner/_NON_BIBLIO/biblio.pdf", hash: "bbb")
        try await add(db, title: "Carnet", path: "\(root)/a/b/_NON_BIBLIO/c/carnet.pdf", hash: "ccc")
        try await add(db, title: "Ailleurs dans b", path: "\(root)/x/b/ailleurs.pdf", hash: "ddd")
        try await add(db, title: "Dans a/b", path: "\(root)/a/b/dedans.pdf", hash: "eee")
        let rules = PublicationRules(excludedFolders: ["_NON_BIBLIO/", "a/b"])
        let (catalogue, report) = try await CatalogPublisher(db: db).build(root: root, rules: rules)
        #expect(catalogue.editions.map(\.title).sorted() == ["Ailleurs dans b", "Minima moralia"])
        #expect(report.excludedByRule == 3)
        #expect(!rules.excludes(relativePath: "_NON_BIBLIO-pas-prive.pdf"))
        #expect(rules.excludes(relativePath: "Wagner/_NON_BIBLIO/biblio.pdf"))
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
            .publish(root: root, rules: rules, to: out, coversFolder: covers, includeDatabase: true)
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

        // Republier sans changement ne réécrit pas le manifeste.
        let date = try fm.attributesOfItem(atPath: out.appendingPathComponent("catalogue.json").path)[.modificationDate] as? Date
        let again = try await CatalogPublisher(db: db)
            .publish(root: root, rules: rules, to: out, coversFolder: covers, includeDatabase: true)
        #expect(again.unchanged)
        #expect(again.editions == report.editions)
        #expect(try fm.attributesOfItem(atPath: out.appendingPathComponent("catalogue.json").path)[.modificationDate] as? Date == date)
    }

    @Test("Face cachée : annotations et encres des seuls documents publiés, stables d'une publication à l'autre")
    func annotations() async throws {
        let db = try await seeded()
        let (publie, prive) = try await db.pool.read { conn in
            (try UUID.fetchOne(conn, sql: "SELECT id FROM document WHERE contentHash = 'aaa' AND filePath LIKE '%Minima.pdf'")!,
             try UUID.fetchOne(conn, sql: "SELECT id FROM document WHERE contentHash = 'bbb'")!)
        }
        let a = Annotation(documentId: publie, pageNumber: 12, quote: "La vie ne vit pas", suffix: ".", note: "clé", color: "jaune")
        let b = Annotation(documentId: publie, pageNumber: 40, quote: "Il n'est pas de vraie vie")
        let c = Annotation(documentId: prive, pageNumber: 1, quote: "journal")
        try await db.pool.write { conn in
            try a.insert(conn); try b.insert(conn); try c.insert(conn)
            try Link(kind: "reprise", sourceAnnotationId: a.id, targetAnnotationId: b.id).insert(conn)
            try Link(kind: "privé", sourceAnnotationId: a.id, targetAnnotationId: c.id).insert(conn)
        }
        let json = try await CatalogPublisher.annotationsJSON(db: db, hashes: ["aaa"])
        let objet = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let notes = try #require(objet["annotations"] as? [[String: Any]])
        #expect(notes.map { $0["citation"] as? String } == ["La vie ne vit pas", "Il n'est pas de vraie vie"])
        #expect(notes[0]["sha256"] as? String == "aaa")
        #expect(notes[0]["page"] as? Int == 12)
        #expect(notes[0]["note"] as? String == "clé")
        #expect(notes[0]["apres"] as? String == ".")
        let encres = try #require(objet["encres"] as? [[String: Any]])
        #expect(encres.count == 1, "une encre vers un document non publié ne sort pas")
        #expect(encres.first?["nature"] as? String == "reprise")
        #expect(try await CatalogPublisher.annotationsJSON(db: db, hashes: ["aaa"]) == json)
    }
    @Test("Les reçus d'import restent publiés après suppression locale, sans détail privé")
    func importReceipts() async throws {
        let db = try CatalogDatabase(inMemory: ())
        try await db.pool.write { conn in
            try conn.execute(sql: "INSERT INTO annotation_import (opId, fonds, seq, result, detail, appliedAt) VALUES (?, ?, ?, ?, ?, ?)",
                             arguments: ["operation", "ajil", 42, "applique", "detail-prive", Date()])
        }
        let data = try await CatalogPublisher.annotationsJSON(db: db, hashes: [])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let receipts = try #require(object["importations"] as? [[String: Any]])
        #expect(receipts.count == 1)
        #expect(receipts[0]["opId"] as? String == "operation")
        #expect(receipts[0]["fonds"] as? String == "ajil")
        #expect(receipts[0]["seq"] as? Int == 42)
        #expect(receipts[0]["resultat"] as? String == "applique")
        #expect(!String(decoding: data, as: UTF8.self).contains("detail-prive"))
        #expect((object["annotations"] as? [Any])?.isEmpty == true)
        #expect(try await CatalogPublisher.annotationsJSON(db: db, hashes: []) == data)
    }

}
