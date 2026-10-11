import Foundation
import Testing
import GRDB
@testable import IshtarSearch
@testable import IshtarCatalog

@Suite("T-037 — import Rayons sur catalogues synthétiques")
struct AnnotationImportTests {
    private let sha = String(repeating: "ab", count: 32)
    private let initial = "2026-01-02T03:04:05.123Z"
    private let later = "2026-01-02T03:04:06.456Z"

    private func fixture() async throws -> (CatalogDatabase, UUID) {
        let db = try CatalogDatabase(inMemory: ())
        let work = Work(title: "Ouvrage synthétique")
        let edition = Edition(workId: work.id)
        let doc = Document(editionId: edition.id, filePath: "/fixture/livre.pdf", originalFileName: "livre.pdf", fileSize: 1, contentHash: sha, format: .pdf)
        try await db.pool.write { conn in try work.insert(conn); try edition.insert(conn); try doc.insert(conn) }
        return (db, doc.id)
    }
    private func operation(seq: Int64 = 1, id: UUID = UUID(), op: String = "poser", base: String? = nil, t: String? = nil) -> AnnotationImport.Operation {
        let time = t ?? initial
        let snapshot = AnnotationImport.Snapshot(id: id.uuidString, sha256: sha, sorte: "note", citation: "Une phrase inventée", page: 2, note: "Note inventée", date: initial, modifie: op == "retirer" ? (base ?? initial) : time)
        return AnnotationImport.Operation(seq: seq, opId: UUID().uuidString, op: op, id: id.uuidString, sha256: sha, base: base, t: time, auteur: "donateur@example.org", instantane: snapshot)
    }
    private func run(_ ops: [AnnotationImport.Operation], db: CatalogDatabase, fonds: String = "fiction", batchFonds: String = "fiction", apply: Bool = true) async throws -> AnnotationImport.Report {
        try await AnnotationImport().importer(.init(fonds: batchFonds, ops: ops), fonds: fonds, in: db.pool, appliquer: apply)
    }
    private func annotations(_ db: CatalogDatabase) async throws -> [Annotation] {
        try await db.pool.read { try Annotation.fetchAll($0) }
    }

    @Test("Replay et acquittement perdu : un UUID BLOB, une seule annotation et une seule trace")
    func replay() async throws {
        let (db, doc) = try await fixture()
        let op = operation()
        #expect(try await run([op], db: db).appliquees == 1)
        let replay = try await run([op], db: db)
        #expect(replay.deja == 1 && replay.appliquees == 0 && replay.rejetees == 0)
        #expect(replay.resultats[0].opId == op.opId && replay.resultats[0].seq == op.seq)
        let stored = try #require(try await annotations(db).first)
        #expect(stored.documentId == doc && stored.kind == "note" && stored.origin == "reader")
        let storedRow = try await db.pool.read { try Row.fetchOne($0, sql: "SELECT typeof(id) AS a, length(id) AS n, typeof(documentId) AS d FROM annotation") }
        let row = try #require(storedRow)
        #expect(row["a"] as String == "blob" && row["d"] as String == "blob" && row["n"] as Int == 16)
        let traceRow = try await db.pool.read { try Row.fetchOne($0, sql: "SELECT typeof(annotationId) AS a, detail FROM annotation_import") }
        let trace = try #require(traceRow)
        #expect(trace["a"] as String == "blob")
        #expect((trace["detail"] as String).contains("Note inventée"))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(replay)) as? [String: Any])
        #expect(json["deja"] as? Int == 1 && json["rejetees"] as? Int == 0)
    }

    @Test("Simulation : opérations dépendantes triées, aucune annotation ni trace conservée")
    func simulationEtOrdre() async throws {
        let (db, _) = try await fixture()
        let pose = operation()
        let change = operation(seq: 2, id: UUID(uuidString: pose.id)!, op: "modifier", base: initial, t: later)
        let simulated = try await run([change, pose], db: db, apply: false)
        #expect(simulated.appliquees == 2 && simulated.resultats.map(\.seq) == [1, 2])
        #expect(try await annotations(db).isEmpty)
        #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM annotation_import") } == 0)
        #expect(try await run([change, pose], db: db) == simulated)
        let updated = try #require(try await annotations(db).first)
        #expect(Int64((updated.dateModified.timeIntervalSince1970 * 1000).rounded()) == 1767323046456)
    }

    @Test("Modification à la base exacte ; conflit conservé et rejeté au replay")
    func conflit() async throws {
        let (db, _) = try await fixture()
        let pose = operation()
        _ = try await run([pose], db: db)
        var change = operation(seq: 2, id: UUID(uuidString: pose.id)!, op: "modifier", base: initial, t: later)
        change.instantane.note = "Nouvelle note"
        #expect(try await run([change], db: db).appliquees == 1)
        let stale = operation(seq: 3, id: UUID(uuidString: pose.id)!, op: "modifier", base: initial, t: "2026-01-02T03:04:07.789Z")
        let rejection = try await run([stale], db: db)
        #expect(rejection.resultats[0].motif == "conflit")
        #expect(try await run([stale], db: db) == rejection)
        #expect(try await annotations(db).first?.note == "Nouvelle note")
    }

    @Test("Retrait : conflit avant effacement, puis trace et replay malgré l'absence")
    func retrait() async throws {
        let (db, _) = try await fixture()
        let pose = operation()
        _ = try await run([pose], db: db)
        var bad = operation(seq: 2, id: UUID(uuidString: pose.id)!, op: "retirer", base: "2026-01-02T03:04:05.122Z", t: later)
        bad.instantane.modifie = initial
        #expect(try await run([bad], db: db).resultats[0].motif == "conflit")
        let remove = operation(seq: 3, id: UUID(uuidString: pose.id)!, op: "retirer", base: initial, t: later)
        #expect(try await run([remove], db: db).appliquees == 1)
        #expect(try await annotations(db).isEmpty)
        #expect(try await run([remove], db: db).deja == 1)
        let resurrection = operation(seq: 4, id: UUID(uuidString: pose.id)!)
        #expect(try await run([resurrection], db: db).resultats[0].motif == "id retiré")
    }

    @Test("Fonds obligatoire : lot et opération étrangers refusés avant le replay")
    func fonds() async throws {
        let (db, _) = try await fixture()
        var op = operation()
        #expect(try await run([op], db: db, batchFonds: "ailleurs").resultats[0].motif == "fonds étranger")
        op.fonds = "ailleurs"
        #expect(try await run([op], db: db).rejetees == 1)
        op.fonds = nil
        _ = try await run([op], db: db)
        #expect(try await run([op], db: db, fonds: "ailleurs", batchFonds: "ailleurs").resultats[0].motif == "fonds étranger")
        await #expect(throws: AnnotationImport.ImportError.self) { try await run([op], db: db, fonds: " ") }
    }

    @Test("Un UUID ne change jamais de document, pour poser, modifier ou retirer")
    func idDetourne() async throws {
        let (db, doc) = try await fixture()
        let otherHash = String(repeating: "cd", count: 32)
        let editionId = try #require(try await db.pool.read { try Document.fetchOne($0, key: doc)?.editionId })
        let other = Document(editionId: editionId, filePath: "/fixture/autre.pdf", originalFileName: "autre.pdf", fileSize: 1, contentHash: otherHash, format: .pdf)
        try await db.pool.write { try other.insert($0) }
        let pose = operation()
        _ = try await run([pose], db: db)
        for verb in ["poser", "modifier", "retirer"] {
            var diverted = operation(seq: 2, id: UUID(uuidString: pose.id)!, op: verb, base: verb == "poser" ? nil : initial, t: later)
            diverted.sha256 = otherHash; diverted.instantane.sha256 = otherHash
            #expect(try await run([diverted], db: db).resultats[0].motif == "id détourné")
        }
        #expect(try await annotations(db).first?.documentId == doc)
    }

    @Test("Empreinte absente, id occupé et opId réutilisé : aucune écriture d'annotation")
    func absencesEtReutilisation() async throws {
        let (db, _) = try await fixture()
        var absent = operation()
        absent.sha256 = String(repeating: "ef", count: 32); absent.instantane.sha256 = absent.sha256
        #expect(try await run([absent], db: db).resultats[0].motif == "document absent")
        let pose = operation()
        _ = try await run([pose], db: db)
        var duplicate = pose; duplicate.opId = UUID().uuidString; duplicate.seq = 3
        #expect(try await run([duplicate], db: db).deja == 1)
        duplicate.opId = UUID().uuidString; duplicate.instantane.note = "Autre"
        #expect(try await run([duplicate], db: db).resultats[0].motif == "id existant")
        var stolen = pose; stolen.instantane.note = "Autre"
        #expect(try await run([stolen], db: db).resultats[0].motif == "opId réutilisé")
        #expect(try await annotations(db).count == 1)
    }

    @Test("Dessins, traits, bornes et instantané désaccordé sont refusés")
    func validation() async throws {
        let (db, _) = try await fixture()
        for kind in ["dessin", "trait", "drawing", "stroke"] {
            var op = operation(); op.instantane.sorte = kind
            #expect(try await run([op], db: db).rejetees == 1)
        }
        var op = operation(); op.instantane.dessin = .object([:])
        #expect(try await run([op], db: db).rejetees == 1)
        op = operation(); op.instantane.id = UUID().uuidString
        #expect(try await run([op], db: db).rejetees == 1)
        op = operation(); op.instantane.note = String(repeating: "a", count: 20_001)
        #expect(try await run([op], db: db).rejetees == 1)
        op = operation(); op.instantane.sorte = "surlignement"
        #expect(try await run([op], db: db).appliquees == 1)
        #expect(try await annotations(db).first?.kind == nil)
    }

    @Test("Une erreur SQLite annule tout le lot, annotations et journal ensemble")
    func transaction() async throws {
        let (db, _) = try await fixture()
        try await db.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse_trace BEFORE INSERT ON annotation_import WHEN NEW.seq = 2 BEGIN SELECT RAISE(ABORT, 'fixture'); END") }
        await #expect(throws: (any Error).self) { try await run([operation(), operation(seq: 2)], db: db) }
        #expect(try await annotations(db).isEmpty)
        #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM annotation_import") } == 0)
    }
    @Test("Copie synthétique : l'import préserve collections, présentations et migrations")
    func copieEtCollections() async throws {
        let (source, doc) = try await fixture()
        let collection = BookCollection(name: "Collection inventée")
        try await source.pool.write { conn in
            let edition = try #require(try Document.fetchOne(conn, key: doc))
            let work = try #require(try Edition.fetchOne(conn, key: edition.editionId))
            try collection.insert(conn)
            try CollectionItem(collectionId: collection.id, workId: work.workId).insert(conn)
            try DocumentPresentation(documentId: doc, kind: .manuscrit, label: "Feuillet inventé", preferred: true).insert(conn)
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("t037-copy-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let copy = try CatalogDatabase(at: path)
        try source.pool.backup(to: copy.pool)
        let migrations = try await copy.appliedMigrationIdentifiers()
        #expect(try await run([operation()], db: copy).appliquees == 1)
        #expect(try await source.pool.read { try Annotation.fetchCount($0) } == 0)
        #expect(try await copy.pool.read { try BookCollection.fetchOne($0, key: collection.id)?.name } == collection.name)
        #expect(try await copy.pool.read { try CollectionItem.fetchCount($0) } == 1)
        #expect(try await copy.pool.read { try DocumentPresentation.fetchOne($0, key: doc)?.kind } == .manuscrit)
        #expect(try await copy.appliedMigrationIdentifiers() == migrations)
        #expect(try await copy.pool.read { try String.fetchOne($0, sql: "PRAGMA quick_check") } == "ok")
    }

    @Test("Couleur PDF historique conservée en modification ; retrait PDF refusé et date future non décroissante")
    func historiquePDF() async throws {
        let (db, doc) = try await fixture()
        let date = Date(timeIntervalSince1970: 1767323045.123)
        let old = Annotation(documentId: doc, pageNumber: 2, quote: "Une phrase inventée", note: "Note ancienne", color: "yellow", dateCreated: date, dateModified: date, origin: "pdf")
        try await db.pool.write { try old.insert($0) }
        var change = operation(seq: 2, id: old.id, op: "modifier", base: initial, t: later)
        change.instantane.sorte = "surlignement"
        change.instantane.couleur = "yellow"
        change.instantane.origine = "pdf"
        #expect(try await run([change], db: db).appliquees == 1)
        #expect(try await annotations(db).first?.color == "yellow")
        #expect(try await annotations(db).first?.origin == "pdf")
        var remove = operation(seq: 3, id: old.id, op: "retirer", base: later, t: "2026-01-02T03:04:07.789Z")
        remove.instantane.sorte = "surlignement"
        remove.instantane.couleur = "yellow"
        remove.instantane.origine = "pdf"
        #expect(try await run([remove], db: db).resultats[0].motif == "retrait PDF non pris en charge")
        var other = operation(seq: 4, id: old.id, op: "modifier", base: later, t: "2026-01-02T03:04:07.789Z")
        other.instantane.couleur = "purple"
        #expect(try await run([other], db: db).resultats[0].motif == "couleur non prise en charge")
        var backwards = change; backwards.seq = 5; backwards.opId = UUID().uuidString
        backwards.base = later
        #expect(try await run([backwards], db: db).resultats[0].motif == "date non croissante")
        #expect(try await annotations(db).count == 1)
    }

    @Test("Commande réelle sur copie synthétique : simulation, application et replay JSON")
    func commande() async throws {
        let (source, _) = try await fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t037-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("copie.sqlite")
        let copy = try CatalogDatabase(at: database)
        try source.pool.backup(to: copy.pool)
        let batch = AnnotationImport.Batch(fonds: "fiction", ops: [operation(), drawingOperation(kind: "dessin", seq: 2), drawingOperation(kind: "trait", seq: 3)])
        let export = directory.appendingPathComponent("lot.json")
        try JSONEncoder().encode(batch).write(to: export)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["ISHTAR_TEST_CLI"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".build/debug/ishtar")
        func invoke(apply: Bool) throws -> AnnotationImport.Report {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["annotations-importer", "--db", database.path, "--fonds", "fiction", "--ops", export.path] + (apply ? ["--appliquer"] : [])
            let output = Pipe(); let error = Pipe()
            process.standardOutput = output; process.standardError = error
            try process.run(); process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errors = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(process.terminationStatus == 0, "\(errors)")
            return try JSONDecoder().decode(AnnotationImport.Report.self, from: data)
        }
        #expect(try invoke(apply: false).appliquees == 3)
        #expect(try await annotations(copy).isEmpty)
        #expect(try invoke(apply: true).appliquees == 3)
        #expect(try invoke(apply: true).deja == 3)
        #expect(try await annotations(copy).count == 3)
        #expect(try await annotations(source).isEmpty)
    }

    @Test("Deux documents de même empreinte restent ambigus, même avec un UUID connu")
    func documentAmbigu() async throws {
        let (db, doc) = try await fixture()
        let edition = try #require(try await db.pool.read { try Document.fetchOne($0, key: doc)?.editionId })
        let duplicate = Document(editionId: edition, filePath: "/fixture/doublon.pdf", originalFileName: "doublon.pdf", fileSize: 1, contentHash: sha, format: .pdf)
        try await db.pool.write { try duplicate.insert($0) }
        #expect(try await run([operation()], db: db).resultats[0].motif == "document ambigu")
        #expect(try await annotations(db).isEmpty)
    }

    @Test("Un fichier remplacé conserve sa géométrie historique, sans autoriser une géométrie étrangère nouvelle")
    func geometrieHistorique() async throws {
        let (db, doc) = try await fixture()
        let geometry = AnnotationGeometry(sha256: String(repeating: "cd", count: 32), pages: [.init(page: 2, rects: [[0.1, 0.2, 0.3, 0.04]])])
        let date = Date(timeIntervalSince1970: 1767323045.123)
        let existing = Annotation(documentId: doc, pageNumber: 2, quote: "Une phrase inventée", dateCreated: date, dateModified: date, origin: "app", geometry: geometry.json)
        try await db.pool.write { try existing.insert($0) }
        var change = operation(seq: 2, id: existing.id, op: "modifier", base: initial, t: later)
        change.instantane.sorte = "surlignement"
        change.instantane.geometrie = geometry
        #expect(try await run([change], db: db).appliquees == 1)
        #expect(try await annotations(db).first?.geometry == geometry.json)
        var pose = operation(); pose.instantane.geometrie = geometry
        #expect(try await run([pose], db: db).resultats[0].motif == "géométrie étrangère")
    }

    private func vector() -> AnnotationImport.JSONValue {
        .object(["largeur": .number(640), "hauteur": .number(480), "traits": .array([
            .object(["couleur": .string("noir"), "epaisseur": .number(0.01),
                     "points": .array([.array([.number(0.1), .number(0.2), .number(0.3)]),
                                       .array([.number(0.8), .number(0.9), .number(1)])])])
        ])])
    }
    private func drawingOperation(kind: String, seq: Int64 = 1, id: UUID = UUID(), op: String = "poser", base: String? = nil, t: String? = nil) -> AnnotationImport.Operation {
        var value = operation(seq: seq, id: id, op: op, base: base, t: t)
        value.instantane.sorte = kind; value.instantane.dessin = vector()
        if kind == "trait" { value.instantane.citation = "" }
        return value
    }

    @Test("Dessins et traits : édition atomique, replay, conflits, UUID BLOB, publication et cascade")
    func dessinsCycle() async throws {
        for kind in ["dessin", "trait"] {
            let (db, _) = try await fixture()
            let pose = drawingOperation(kind: kind)
            #expect(try await run([pose], db: db).appliquees == 1)
            #expect(try await run([pose], db: db).deja == 1)
            var duplicate = pose; duplicate.opId = UUID().uuidString; duplicate.seq = 2
            #expect(try await run([duplicate], db: db).deja == 1)
            duplicate.instantane.dessin = .object([:]); duplicate.opId = pose.opId
            #expect(try await run([duplicate], db: db).resultats[0].motif == "opId réutilisé")
            #expect(try await run([pose], db: db, batchFonds: "étranger").rejetees == 1)
            let project = Project(name: "Projet synthétique")
            try await db.pool.write { conn in
                try project.insert(conn)
                try conn.execute(sql: "UPDATE annotation SET projectId = ?, origin = 'app' WHERE id = ?", arguments: [project.id, UUID(uuidString: pose.id)!])
            }
            let originalDate = try #require(try await annotations(db).first).dateCreated
            var change = drawingOperation(kind: kind, seq: 2, id: UUID(uuidString: pose.id)!, op: "modifier", base: initial, t: later)
            var fields: [String: AnnotationImport.JSONValue] = [:]
            if case let .object(v) = vector() { fields = v }
            fields["largeur"] = .number(800); change.instantane.dessin = .object(fields)
            #expect(try await run([change], db: db).appliquees == 1)
            #expect(try await run([change], db: db).deja == 1)
            let saved = try #require(try await annotations(db).first)
            #expect(saved.projectId == project.id && saved.origin == "app")
            #expect(saved.dateCreated == originalDate)
            var stale = change; stale.opId = UUID().uuidString; stale.instantane.dessin = vector()
            #expect(try await run([stale], db: db).resultats[0].motif == "conflit")
            #expect(try await run([stale], db: db).rejetees == 1)
            let row = try #require(try await db.pool.read { try Row.fetchOne($0, sql: "SELECT typeof(annotationId) AS type, width, strokes, svg FROM annotation_drawing") })
            #expect(row["type"] as String == "blob" && row["width"] as Double == 800)
            #expect((row["strokes"] as String).contains("0.3"))
            #expect((row["svg"] as String).contains("<svg") && !(row["svg"] as String).contains("script"))
            try await db.pool.write { try $0.execute(sql: "UPDATE annotation_drawing SET svg = '<script>fixture</script>'") }
            let published = try await CatalogPublisher.annotationsJSON(db: db, hashes: [sha])
            let root = try #require(try JSONSerialization.jsonObject(with: published) as? [String: Any])
            let notes = try #require(root["annotations"] as? [[String: Any]])
            #expect(notes.first?["sorte"] as? String == kind)
            let publishedSVG = try #require(notes.first?["svg"] as? String)
            #expect(!publishedSVG.contains("<script"))
            #expect((notes.first?["dessin"] as? [String: Any])?["largeur"] as? Double == 800)
            let remove = drawingOperation(kind: kind, seq: 3, id: UUID(uuidString: pose.id)!, op: "retirer", base: later, t: "2026-01-02T03:04:07.789Z")
            #expect(try await run([remove], db: db).appliquees == 1)
            #expect(try await run([remove], db: db).deja == 1)
            #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM annotation_drawing") } == 0)
        }
    }

    @Test("Vecteurs : bornes, pression, nombres finis et limites cumulées")
    func dessinsBornes() {
        let stroke = AnnotationDrawing.Stroke(couleur: "klein", epaisseur: 0.001, points: [[0, 1, 0]])
        let valid = AnnotationDrawing(largeur: 100, hauteur: 4096, traits: [stroke])
        #expect(valid.isValid)
        for n in [Double.nan, .infinity, 99, 4097] {
            var d = valid; d.largeur = n; #expect(!d.isValid && d.svg == nil)
        }
        for point in [[0.0, 1], [0, 1, -0.1], [0, 1.1, 0], [0, 1, Double.nan]] {
            var d = valid; d.traits[0].points = [point]; #expect(!d.isValid)
        }
        var d = valid; d.traits[0].couleur = "<script>"; #expect(!d.isValid)
        d = valid; d.traits[0].epaisseur = 0.051; #expect(!d.isValid)
        d = valid; d.traits[0].points = []; #expect(!d.isValid)
        d = valid; d.traits[0].points = Array(repeating: [0, 0, 1], count: 4097); #expect(!d.isValid)
        d = valid; d.traits = Array(repeating: stroke, count: 129); #expect(!d.isValid)
        d = valid; d.traits = Array(repeating: .init(couleur: "redon", epaisseur: 0.05, points: Array(repeating: [0, 0, 1], count: 4000)), count: 3)
        #expect(d.isValid)
        d.traits.append(stroke); #expect(!d.isValid)
    }

    @Test("Import dessin : format, page, citation, géométrie étrangère, sorte et SVG client")
    func dessinsValidation() async throws {
        let (db, doc) = try await fixture()
        for kind in ["dessin", "trait"] {
            var op = drawingOperation(kind: kind); op.instantane.svg = "<svg/>"
            #expect(try await run([op], db: db).rejetees == 1)
            op = drawingOperation(kind: kind); op.instantane.page = 100001
            #expect(try await run([op], db: db).rejetees == 1)
            op = drawingOperation(kind: kind)
            op.instantane.geometrie = .init(sha256: String(repeating: "cd", count: 32), pages: [.init(page: 2, rects: [[0, 0, 1, 1]])])
            #expect(try await run([op], db: db).resultats[0].motif == "géométrie étrangère")
        }
        let otherHash = String(repeating: "ef", count: 32)
        let editionId = try #require(try await db.pool.read { try Document.fetchOne($0, key: doc)?.editionId })
        let other = Document(editionId: editionId, filePath: "/fixture/foreign.pdf", originalFileName: "foreign.pdf", fileSize: 1, contentHash: otherHash, format: .pdf)
        try await db.pool.write { try other.insert($0) }
        let drawing = drawingOperation(kind: "dessin")
        _ = try await run([drawing], db: db)
        var foreign = drawingOperation(kind: "dessin", seq: 2, id: UUID(uuidString: drawing.id)!, op: "modifier", base: initial, t: later)
        foreign.sha256 = otherHash; foreign.instantane.sha256 = otherHash
        #expect(try await run([foreign], db: db).resultats[0].motif == "id détourné")
        var bad = drawingOperation(kind: "trait"); bad.instantane.page = nil
        #expect(try await run([bad], db: db).rejetees == 1)
        bad = drawingOperation(kind: "dessin"); bad.instantane.citation = " "
        #expect(try await run([bad], db: db).rejetees == 1)
        try await db.pool.write { try $0.execute(sql: "UPDATE document SET format = 'epub' WHERE id = ?", arguments: [doc]) }
        #expect(try await run([drawingOperation(kind: "trait")], db: db).rejetees == 1)
        let pose = drawingOperation(kind: "dessin")
        #expect(try await run([pose], db: db).appliquees == 1)
        var change = drawingOperation(kind: "dessin", seq: 2, id: UUID(uuidString: pose.id)!, op: "modifier", base: initial, t: later)
        change.instantane.sorte = "note"; change.instantane.dessin = nil
        #expect(try await run([change], db: db).resultats[0].motif == "sorte immuable")
        try await db.pool.write { try $0.execute(sql: "UPDATE document SET format = 'txt' WHERE id = ?", arguments: [doc]) }
        #expect(try await run([drawingOperation(kind: "dessin")], db: db).rejetees == 1)
    }

    @Test("Dessin : simulation sans mutation et erreur de stockage annulant annotation et reçu")
    func dessinsTransaction() async throws {
        let (db, _) = try await fixture()
        let pose = drawingOperation(kind: "dessin")
        let change = drawingOperation(kind: "dessin", seq: 2, id: UUID(uuidString: pose.id)!, op: "modifier", base: initial, t: later)
        #expect(try await run([change, pose], db: db, apply: false).appliquees == 2)
        #expect(try await annotations(db).isEmpty)
        #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM annotation_drawing") } == 0)
        try await db.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse_drawing BEFORE INSERT ON annotation_drawing BEGIN SELECT RAISE(ABORT, 'fixture'); END") }
        await #expect(throws: (any Error).self) { try await run([pose], db: db) }
        #expect(try await annotations(db).isEmpty)
        #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM annotation_import") } == 0)
    }

    @Test("Échec de l'édition des vecteurs : ancienne annotation, dessin et reçu restent cohérents")
    func dessinsEditionAtomique() async throws {
        let (db, _) = try await fixture()
        let pose = drawingOperation(kind: "trait")
        _ = try await run([pose], db: db)
        let before = try await annotations(db)
        try await db.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse_edit BEFORE UPDATE ON annotation_drawing BEGIN SELECT RAISE(ABORT, 'fixture'); END") }
        var edit = drawingOperation(kind: "trait", seq: 2, id: UUID(uuidString: pose.id)!, op: "modifier", base: initial, t: later)
        edit.instantane.note = "Édition qui doit disparaître"
        await #expect(throws: (any Error).self) { try await run([edit], db: db) }
        #expect(try await annotations(db) == before)
        #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM annotation_import") } == 1)
        #expect(try await db.pool.read { try Double.fetchOne($0, sql: "SELECT width FROM annotation_drawing") } == 640)
    }

    @Test("Un nombre non fini injecté en Swift est rejeté sans mutation")
    func dessinsNonFinisImport() async throws {
        let (db, _) = try await fixture()
        var op = drawingOperation(kind: "dessin")
        if case var .object(fields) = op.instantane.dessin! {
            fields["largeur"] = .number(.infinity); op.instantane.dessin = .object(fields)
        }
        #expect(try await run([op], db: db).rejetees == 1)
        #expect(try await annotations(db).isEmpty)
    }

    @Test("Fichier falsifié : schéma dessin fermé, SVG et clés inconnues imbriqués rejetés avec reçu")
    func dessinsSchemaFerme() async throws {
        let (db, _) = try await fixture()
        let fields: [String: AnnotationImport.JSONValue]
        guard case let .object(original) = vector() else { return }
        fields = original
        for key in ["svg", "inconnu"] {
            for nested in [false, true] {
                var altered = fields
                if nested, case var .array(strokes) = altered["traits"], case var .object(stroke) = strokes[0] {
                    stroke[key] = .string("<script/>"); strokes[0] = .object(stroke); altered["traits"] = .array(strokes)
                } else { altered[key] = .string("<script/>") }
                var op = drawingOperation(kind: "dessin"); op.instantane.dessin = .object(altered)
                // Passage par du JSON brut : même frontière qu'un fichier de file falsifié.
                let raw = try JSONEncoder().encode(AnnotationImport.Batch(fonds: "fiction", ops: [op]))
                let batch = try JSONDecoder().decode(AnnotationImport.Batch.self, from: raw)
                let report = try await AnnotationImport().importer(batch, fonds: "fiction", in: db.pool, appliquer: true)
                #expect(report.rejetees == 1)
                #expect(try await run([op], db: db) == report)
            }
        }
        #expect(try await annotations(db).isEmpty)
        #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM annotation_import") } == 4)
    }

    @Test("SVG : pression moyenne du segment et rayon du point, palette et petit côté")
    func dessinsPressionSVG() throws {
        let drawing = AnnotationDrawing(largeur: 800, hauteur: 400, traits: [
            .init(couleur: "redon", epaisseur: 0.01, points: [[0, 0, 0], [1, 1, 1]])
        ])
        let svg = try #require(drawing.svg)
        // Point de pression nulle : 4 * .25 / 2 ; segment : 4 * (.25 + .75 * .5).
        #expect(svg.contains("r=\"0.5\""))
        #expect(svg.contains("stroke-width=\"2.5\""))
        #expect(svg.contains("#A33A32"))
        #expect(svg.contains("M 0.0 0.0 L 800.0 400.0"))
        let points = try #require(drawing.strokesJSON)
        #expect(points.contains("[0,0,0]") && points.contains("[1,1,1]"))
    }

}
