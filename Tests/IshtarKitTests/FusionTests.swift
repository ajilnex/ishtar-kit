import Testing
import Foundation
import GRDB
@testable import IshtarCatalog
@testable import IshtarSearch

@Suite("Fusionner deux éditions à clés figées")
struct FusionTests {
    struct Ids { var work: UUID; var edition: UUID; var docs: [UUID] }

    /// Une œuvre, une édition à clé donnée, n documents ; chaque document reçoit des annotations.
    private func add(_ db: CatalogDatabase, title: String, key: String, origin: EditionKey.Origin = .stable,
                     files: [String], annotations: Int = 2, author: String = "Auteur Inventé") async throws -> Ids {
        try await db.pool.write { conn in
            let work = Work(title: title, notes: "Note de \(title)")
            try work.insert(conn)
            let creator = try Creator.fetchOne(conn, sql: "SELECT * FROM creator WHERE name = ?", arguments: [author])
                ?? { let c = Creator(name: author); try c.insert(conn); return c }()
            try WorkCreator(workId: work.id, creatorId: creator.id).insert(conn)
            let edition = Edition(workId: work.id, year: "1999")
            try edition.insert(conn)
            try EditionKey(editionId: edition.id, key: key, origin: origin).insert(conn)
            var docs: [UUID] = []
            for f in files {
                let d = Document(editionId: edition.id, filePath: "/lib/\(f)", originalFileName: f,
                                 fileSize: 10, contentHash: "h-\(f)", format: .pdf, curationStatus: .recognized)
                try d.insert(conn)
                docs.append(d.id)
                for i in 0..<annotations {
                    try Annotation(documentId: d.id, pageNumber: i + 1, quote: "citation \(f) \(i)").insert(conn)
                }
            }
            return Ids(work: work.id, edition: edition.id, docs: docs)
        }
    }

    private func fresh() throws -> CatalogDatabase { try CatalogDatabase(inMemory: ()) }

    private func count(_ db: CatalogDatabase, _ sql: String) async throws -> Int {
        try await db.pool.read { try Int.fetchOne($0, sql: sql) ?? -1 }
    }

    @Test("Cas nominal : documents, annotations, auteurs, collections, pierre, retraits")
    func nominal() async throws {
        let db = try fresh()
        let gardee = try await add(db, title: "Titre gardé", key: "Auteur1999Gardee", files: ["a.pdf"])
        let absorbee = try await add(db, title: "Titre absorbé", key: "Auteur1999Absorbee", files: ["b.pdf", "c.epub"], author: "Autre Inventé")
        try await db.pool.write { conn in
            let c = BookCollection(name: "Série inventée")
            try c.insert(conn)
            try CollectionItem(collectionId: c.id, workId: absorbee.work).insert(conn)
            let e = Creator(name: "Traducteur Inventé")
            try e.insert(conn)
            try EditionCreator(editionId: absorbee.edition, creatorId: e.id, role: .translator).insert(conn)
            try DocumentPresentation(documentId: gardee.docs[0], kind: .livre, preferred: true).insert(conn)
            try DocumentPresentation(documentId: absorbee.docs[0], kind: .livre, preferred: true).insert(conn)
        }
        let r = try await CatalogStore(db: db).mergeEditions(absorbedKey: "auteur1999absorbee", into: "Auteur1999Gardee",
                                                              preuve: "même page de titre", apply: true)
        #expect(r.documents.count == 2)
        #expect(r.annotationsKept == 4)
        #expect(r.workRemoved == "Titre absorbé")
        try await db.pool.read { conn in
            let rows = try Document.filter(Column("editionId") == gardee.edition).fetchAll(conn)
            #expect(Set(rows.map(\.id)) == Set(gardee.docs + absorbee.docs))
            // Annotations : mêmes comptes, par document.
            for id in gardee.docs { #expect(try Annotation.filter(Column("documentId") == id).fetchCount(conn) == 2) }
            for id in absorbee.docs { #expect(try Annotation.filter(Column("documentId") == id).fetchCount(conn) == 2) }
            // Pierre.
            let pierre = try #require(try RetiredKey.fetchOne(conn, key: "Auteur1999Absorbee"))
            #expect(pierre.replacedBy == "Auteur1999Gardee")
            #expect(pierre.reason.hasPrefix("fusionnée"))
            #expect(pierre.reason.contains("même page de titre"))
            // Retraits, et rien d'autre.
            #expect(try Edition.fetchOne(conn, key: absorbee.edition) == nil)
            #expect(try Work.fetchOne(conn, key: absorbee.work) == nil)
            #expect(try Work.fetchOne(conn, key: gardee.work) != nil)
            // Report : notes, collections, auteurs, contributeurs d'édition.
            let work = try #require(try Work.fetchOne(conn, key: gardee.work))
            #expect(work.notes?.contains("Note de Titre absorbé") == true)
            #expect(try CollectionItem.filter(Column("workId") == gardee.work).fetchCount(conn) == 1)
            let authors = try String.fetchAll(conn, sql: """
                SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId WHERE wc.workId = ? ORDER BY wc.position
                """, arguments: [gardee.work])
            #expect(authors == ["Auteur Inventé", "Autre Inventé"])
            #expect(try EditionCreator.filter(Column("editionId") == gardee.edition).fetchCount(conn) == 1)
            // Le préféré de la gardée le reste, celui de l'absorbée est rétrogradé.
            let prefs = try DocumentPresentation.filter(Column("preferred") == true).fetchAll(conn)
            #expect(prefs.map(\.documentId) == [gardee.docs[0]])
            #expect(try EditionKey.fetchOne(conn, key: gardee.edition)?.key == "Auteur1999Gardee")
        }
    }

    @Test("Même œuvre : l'œuvre reste ; œuvre absorbée avec une autre édition : elle reste")
    func oeuvres() async throws {
        let db = try fresh()
        let g = try await add(db, title: "T", key: "A1Gardee", files: ["g.pdf"])
        // Deuxième édition de la même œuvre gardée.
        let e2 = try await db.pool.write { conn -> UUID in
            let e = Edition(workId: g.work); try e.insert(conn)
            try EditionKey(editionId: e.id, key: "A1Soeur", origin: .stable).insert(conn)
            return e.id
        }
        _ = try await CatalogStore(db: db).mergeEditions(absorbedKey: "A1Soeur", into: "A1Gardee", apply: true)
        try await db.pool.read { conn in
            let edition = try Edition.fetchOne(conn, key: e2)
            let work = try Work.fetchOne(conn, key: g.work)
            #expect(edition == nil && work != nil)
        }
        // Œuvre absorbée qui garde une autre édition.
        let a = try await add(db, title: "U", key: "B1Absorbee", files: ["u.pdf"])
        try await db.pool.write { conn in
            let e = Edition(workId: a.work); try e.insert(conn)
            try EditionKey(editionId: e.id, key: "B1Reste", origin: .stable).insert(conn)
        }
        let r = try await CatalogStore(db: db).mergeEditions(absorbedKey: "B1Absorbee", into: "A1Gardee", apply: true)
        #expect(r.workRemoved == nil)
        let reste = try await db.pool.read { try Work.fetchOne($0, key: a.work) }
        #expect(reste != nil)
    }

    @Test("Essai à blanc : rien n'est écrit, rapport identique")
    func essaiABlanc() async throws {
        let db = try fresh()
        _ = try await add(db, title: "G", key: "A1Gardee", files: ["g.pdf"])
        let a = try await add(db, title: "A", key: "A1Absorbee", files: ["a.pdf"])
        let dump = """
            SELECT (SELECT count(*) FROM edition) || '/' || (SELECT count(*) FROM work) || '/' ||
                   (SELECT count(*) FROM edition_key_retired) || '/' || (SELECT count(*) FROM annotation) || '/' ||
                   (SELECT group_concat(editionId) FROM (SELECT editionId FROM document ORDER BY id))
            """
        let avant = try await db.pool.read { try String.fetchOne($0, sql: dump) }
        let r = try await CatalogStore(db: db).mergeEditions(absorbedKey: "A1Absorbee", into: "A1Gardee", apply: false)
        #expect(r.documents.count == 1 && r.annotationsKept == 2)
        let apres = try await db.pool.read { try String.fetchOne($0, sql: dump) }
        #expect(apres == avant)
        let cle = try await db.pool.read { try EditionKey.fetchOne($0, key: a.edition)?.key }
        #expect(cle == "A1Absorbee")
    }

    @Test("Refus : clés identiques, inconnue, pierre ; rien d'écrit")
    func refus() async throws {
        let db = try fresh()
        _ = try await add(db, title: "G", key: "A1Gardee", files: ["g.pdf"])
        _ = try await add(db, title: "A", key: "A1Absorbee", files: ["a.pdf"])
        try await db.pool.write { conn in
            try RetiredKey(key: "A1Pierre", editionId: UUID(), replacedBy: "A1Gardee", reason: "remplacée").insert(conn)
        }
        let store = CatalogStore(db: db)
        await #expect(throws: EditionFusion.Refus.clesIdentiques) {
            try await store.mergeEditions(absorbedKey: "A1Gardee", into: "a1gardee", apply: true)
        }
        await #expect(throws: EditionFusion.Refus.cleInconnue("Nulle")) {
            try await store.mergeEditions(absorbedKey: "Nulle", into: "A1Gardee", apply: true)
        }
        await #expect(throws: EditionFusion.Refus.cleInconnue("Nulle")) {
            try await store.mergeEditions(absorbedKey: "A1Absorbee", into: "Nulle", apply: true)
        }
        await #expect(throws: EditionFusion.Refus.dejaPierre("A1Pierre")) {
            try await store.mergeEditions(absorbedKey: "A1Pierre", into: "A1Gardee", apply: true)
        }
        await #expect(throws: EditionFusion.Refus.dejaPierre("A1Pierre")) {
            try await store.mergeEditions(absorbedKey: "A1Absorbee", into: "A1Pierre", apply: true)
        }
        let ed = try await count(db, "SELECT count(*) FROM edition")
        let st = try await count(db, "SELECT count(*) FROM edition_key_retired")
        #expect(ed == 2 && st == 1)
    }

    @Test("Une annotation qui disparaîtrait fait tout annuler (ROLLBACK)")
    func annotationPerdue() async throws {
        let db = try fresh()
        _ = try await add(db, title: "G", key: "A1Gardee", files: ["g.pdf"])
        _ = try await add(db, title: "A", key: "A1Absorbee", files: ["a.pdf"])
        // Un déclencheur hostile supprime une annotation quand une pierre « fusionnée » est écrite.
        try await db.pool.write { conn in
            try conn.execute(sql: """
                CREATE TRIGGER hostile AFTER UPDATE OF reason ON edition_key_retired
                BEGIN DELETE FROM annotation WHERE id = (SELECT id FROM annotation LIMIT 1); END
                """)
            try conn.execute(sql: """
                CREATE TRIGGER hostile2 AFTER INSERT ON edition_key_retired
                BEGIN DELETE FROM annotation WHERE id = (SELECT id FROM annotation LIMIT 1); END
                """)
        }
        await #expect(throws: EditionFusion.Refus.self) {
            try await CatalogStore(db: db).mergeEditions(absorbedKey: "A1Absorbee", into: "A1Gardee", apply: true)
        }
        let an = try await count(db, "SELECT count(*) FROM annotation")
        let ed = try await count(db, "SELECT count(*) FROM edition")
        let st = try await count(db, "SELECT count(*) FROM edition_key_retired")
        #expect(an == 4 && ed == 2 && st == 0)
    }

    @Test("Pierres en chaîne redirigées ; clé provisoire gardée figée")
    func chaine() async throws {
        let db = try fresh()
        _ = try await add(db, title: "G", key: "A1Gardee", origin: .generated, files: ["g.pdf"])
        let a = try await add(db, title: "A", key: "A1Absorbee", files: ["a.pdf"])
        try await db.pool.write { conn in
            try RetiredKey(key: "A1Ancienne", editionId: a.edition, replacedBy: "A1Absorbee", reason: "remplacée").insert(conn)
            try RetiredKey(key: "A1Orpheline", editionId: a.edition, replacedBy: nil, reason: "supprimée").insert(conn)
            try RetiredKey(key: "A1Autre", editionId: UUID(), replacedBy: "A1Ancienne", reason: "remplacée").insert(conn)
        }
        let r = try await CatalogStore(db: db).mergeEditions(absorbedKey: "A1Absorbee", into: "A1Gardee", apply: true)
        #expect(r.keptKeyFrozen)
        #expect(r.stonesRedirected == 2)
        try await db.pool.read { conn in
            let by = Dictionary(uniqueKeysWithValues: try RetiredKey.fetchAll(conn).map { ($0.key, $0.replacedBy) })
            #expect(by["A1Absorbee"] == "A1Gardee")
            #expect(by["A1Ancienne"] == "A1Gardee")
            #expect(by["A1Orpheline"] == "A1Gardee")
            #expect(by["A1Autre"] == "A1Ancienne")  // suit la chaîne jusqu'à la gardée
            #expect(try EditionKey.fetchAll(conn).first?.origin == .stable)
        }
        let formes = try await CatalogStore(db: db).retiredKeysByEdition()
        let gardee = try await db.pool.read { try UUID.fetchOne($0, sql: "SELECT editionId FROM edition_key") }
        #expect(Set(formes[try #require(gardee)] ?? []) == ["A1Absorbee", "A1Ancienne", "A1Orpheline", "A1Autre"])
    }

    @Test("ishtar publish publie l'ancienne clé dans formerKeys de la gardée")
    func formerKeys() async throws {
        let db = try fresh()
        let root = "/lib"
        _ = try await add(db, title: "G", key: "A1Gardee", files: ["g.pdf"])
        _ = try await add(db, title: "A", key: "A1Absorbee", files: ["a.pdf"])
        _ = try await CatalogStore(db: db).mergeEditions(absorbedKey: "A1Absorbee", into: "A1Gardee", apply: true)
        let (catalogue, _) = try await CatalogPublisher(db: db).build(root: root, rules: PublicationRules())
        #expect(catalogue.editions.count == 1)
        let e = try #require(catalogue.editions.first)
        #expect(e.key == "A1Gardee")
        #expect(e.formerKeys == ["A1Absorbee"])
        #expect(e.files.count == 2)
    }

    @Test("Verrou d'écriture : posé, refusé s'il existe, Ishtar ouverte, fichiers ouverts, levé")
    func verrou() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verrou-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cat = dir.appendingPathComponent("catalog.sqlite")
        let libre = EcritureVerrou.Controles(ishtarOuverte: { false }, fichiersOuverts: { _ in false })
        let ouverte = EcritureVerrou.Controles(ishtarOuverte: { true }, fichiersOuverts: { _ in false })
        let tenu = EcritureVerrou.Controles(ishtarOuverte: { false }, fichiersOuverts: { _ in true })
        #expect(throws: EcritureVerrou.Refus.self) { try EcritureVerrou.poser(pour: cat, qui: "t", pourquoi: "t", controles: ouverte) }
        #expect(throws: EcritureVerrou.Refus.self) { try EcritureVerrou.poser(pour: cat, qui: "t", pourquoi: "t", controles: tenu) }
        let jeton = try EcritureVerrou.poser(pour: cat, qui: "t", pourquoi: "essai", controles: libre)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ecriture.verrou").path))
        #expect(throws: EcritureVerrou.Refus.self) { try EcritureVerrou.poser(pour: cat, qui: "t", pourquoi: "t", controles: libre) }
        jeton.liberer()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ecriture.verrou").path))
    }
}
