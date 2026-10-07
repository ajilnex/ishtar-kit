import Testing
import Foundation
import GRDB
@testable import IshtarCatalog
@testable import IshtarSearch

/// Clés justes, pierres tombales, vérification sur pièces (04/10/2026, demande
/// d'Aubin : « je ne veux pas garder les fausses clés », « des agents qui
/// regardent directement les premières pages »).
@Suite("Clés justes et vérification sur pièces")
struct ClesJustesTests {
    // MARK: Le nom de famille d'une clé

    @Test("Épithètes, particules, forme de classement")
    func family() {
        #expect(CiteKeyGenerator.family("Pline le Jeune") == "PlineLeJeune")
        #expect(CiteKeyGenerator.family("Pline l'Ancien") == "PlineLAncien")
        #expect(CiteKeyGenerator.family("Jean de la Bruyère") == "LaBruyere")
        #expect(CiteKeyGenerator.family("Ursula K. Le Guin") == "LeGuin")
        #expect(CiteKeyGenerator.family("André De Tienne") == "DeTienne")
        #expect(CiteKeyGenerator.family("Michel de Montaigne") == "Montaigne")
        #expect(CiteKeyGenerator.family("Theodor W. Adorno") == "Adorno")
        #expect(CiteKeyGenerator.family("Sun Tzu", sortName: "Sun Tzu") == "SunTzu")
        #expect(CiteKeyGenerator.family("Gabriel García Márquez", sortName: "García Márquez, Gabriel") == "GarciaMarquez")
        #expect(CiteKeyGenerator.family("Eduardo Viveiros de Castro", sortName: "Viveiros de Castro, Eduardo") == "ViveirosDeCastro")
        #expect(CiteKeyGenerator.base(author: "Pline le Jeune", year: "100", title: "Lettres, tome I") == "PlineLeJeune100Lettres")
    }

    @Test("Une clé est juste si elle dit ce que dit la fiche")
    func agreement() {
        #expect(CiteKeyGenerator.agrees(key: "Adorno1951Minima-2003", author: "Theodor W. Adorno", sortName: nil, year: "1951", title: "Minima moralia"))
        #expect(CiteKeyGenerator.agrees(key: "Rosenberg2007WilfridFusing", author: "Jay Rosenberg", sortName: nil, year: "2007",
                                        title: "Wilfrid Sellars: Fusing the Images"))
        #expect(CiteKeyGenerator.agrees(key: "Long1987HellenisticVolume1", author: "A. A. Long", sortName: nil, year: "1987",
                                        title: "The Hellenistic Philosophers. Volume 1"))
        #expect(!CiteKeyGenerator.agrees(key: "Jeune100Lettres", author: "Pline le Jeune", sortName: nil, year: "100", title: "Lettres"))
        #expect(!CiteKeyGenerator.agrees(key: "Kiryushchenko1974Diagrams", author: "Vitaly Kiryushchenko", sortName: nil, year: "2023",
                                         title: "Diagrams, Visual Imagination, and Continuity in Peirce's Philosophy of Mathematics"))
        #expect(!CiteKeyGenerator.agrees(key: "Sellars2012Mythe", author: "Élise Marrou", sortName: nil, year: "2012",
                                         title: "Présentation : Mythes du donné ? Sellars en perspective"))
    }

    // MARK: Pierres tombales

    private func edition(_ conn: Database, title: String, author: String, year: String, key: String? = nil,
                         origin: EditionKey.Origin = .stable, path: String, hash: String) throws -> (edition: UUID, document: UUID) {
        let work = Work(title: title, date: year)
        try work.insert(conn)
        let creator = Creator(name: author)
        try creator.insert(conn)
        try WorkCreator(workId: work.id, creatorId: creator.id).insert(conn)
        let edition = Edition(workId: work.id, year: year)
        try edition.insert(conn)
        let document = Document(editionId: edition.id, filePath: path, originalFileName: (path as NSString).lastPathComponent,
                                fileSize: 10, contentHash: hash, format: .pdf, curationStatus: .recognized)
        try document.insert(conn)
        if let key { try EditionKey(editionId: edition.id, key: key, origin: origin).insert(conn) }
        return (edition.id, document.id)
    }

    @Test("Une clé fausse et figée devient une pierre tombale qui mène à la juste ; jamais redonnée")
    func tombstone() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (pline, autre) = try await db.pool.write { conn in
            let pline = try edition(conn, title: "Lettres", author: "Pline le Jeune", year: "100", key: "Jeune100Lettres",
                                    path: "/lib/Pline.pdf", hash: "aaa").edition
            let autre = try edition(conn, title: "Minima moralia", author: "Theodor W. Adorno", year: "1951", key: "Adorno1951Minima",
                                    path: "/lib/Adorno.pdf", hash: "bbb").edition
            // Une pierre plus ancienne qui menait à la clé fausse.
            try RetiredKey(key: "Pline100Lettres", editionId: pline, replacedBy: "Jeune100Lettres", reason: "essai").insert(conn)
            return (pline, autre)
        }
        let store = CatalogStore(db: db)
        let fausses = try await store.disagreeingKeys()
        #expect(fausses.map(\.key) == ["Jeune100Lettres"])

        let essai = try await store.replaceKeys(editionIds: fausses.map(\.editionId), reason: "fiche vérifiée", dryRun: true)
        #expect(essai.map(\.new) == ["PlineLeJeune100Lettres"])
        #expect(try await store.key(forEdition: pline)?.key == "Jeune100Lettres")   // rien d'écrit à blanc

        let faites = try await store.replaceKeys(editionIds: fausses.map(\.editionId), reason: "fiche vérifiée", dryRun: false)
        #expect(faites == [EditionKey.Change(editionId: pline, old: "Jeune100Lettres", new: "PlineLeJeune100Lettres", retired: true)])
        let nouvelle = try #require(try await store.key(forEdition: pline))
        #expect(nouvelle.origin == .stable)
        let pierres = try await db.pool.read { try RetiredKey.order(Column("key")).fetchAll($0) }
        #expect(pierres.map(\.key) == ["Jeune100Lettres", "Pline100Lettres"])
        #expect(pierres.allSatisfy { $0.replacedBy == "PlineLeJeune100Lettres" && $0.editionId == pline })
        #expect(try await store.key(forEdition: autre)?.key == "Adorno1951Minima")

        // Un autre livre qui donnerait la clé retirée ne la reçoit pas.
        let intrus = try await db.pool.write { conn -> UUID in
            let e = try edition(conn, title: "Lettres", author: "Jacques Jeune", year: "100", path: "/lib/Jeune.pdf", hash: "ccc").edition
            try EditionKey.assignMissing(conn)
            return e
        }
        #expect(try await store.key(forEdition: intrus)?.key != "Jeune100Lettres")
        #expect(try await store.retiredKeysByEdition()[pline]?.sorted() == ["Jeune100Lettres", "Pline100Lettres"])
    }

    @Test("La pierre d'une édition disparue suit replacedBy jusqu'à la clé vivante")
    func tombstoneOfVanishedEdition() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let kant = try await db.pool.write { conn -> UUID in
            let kant = try edition(conn, title: "Critique de la raison pure", author: "Immanuel Kant", year: "1781",
                                   key: "Kant1781Critique", path: "/lib/Kant.pdf", hash: "kkk").edition
            // Fiche absorbée par une réunion : son édition n'existe plus.
            try RetiredKey(key: "Kant1781Critique-2006", editionId: UUID(), replacedBy: "Kant1781Critique", reason: "essai").insert(conn)
            // Chaîne : une pierre qui mène à une autre pierre, puis à la clé vivante.
            try RetiredKey(key: "Kant1781Raison", editionId: UUID(), replacedBy: "Kant1781Critique-2006", reason: "essai").insert(conn)
            // Fiche supprimée sans remplaçante : rattachée à rien.
            try RetiredKey(key: "Doyle1893Memoirs", editionId: UUID(), replacedBy: nil, reason: "essai").insert(conn)
            return kant
        }
        let parEdition = try await CatalogStore(db: db).retiredKeysByEdition()
        #expect(parEdition[kant]?.sorted() == ["Kant1781Critique-2006", "Kant1781Raison"])
        #expect(parEdition.values.allSatisfy { !$0.contains("Doyle1893Memoirs") })
    }

    @Test("Effacer une clé figée laisse une pierre ; une clé provisoire, non")
    func deletion() async throws {
        let db = try CatalogDatabase(inMemory: ())
        try await db.pool.write { conn in
            let a = try edition(conn, title: "Un", author: "A B", year: "2000", key: "B2000Un", origin: .stable, path: "/lib/a.pdf", hash: "a").edition
            let b = try edition(conn, title: "Deux", author: "C D", year: "2000", key: "D2000Deux", origin: .generated, path: "/lib/b.pdf", hash: "b").edition
            try conn.execute(sql: "DELETE FROM edition_key WHERE editionId IN (?, ?)", arguments: [a, b])
        }
        let pierres = try await db.pool.read { try RetiredKey.fetchAll($0) }
        #expect(pierres.map(\.key) == ["B2000Un"])
        #expect(pierres.first?.reason == "supprimée")
    }

    // MARK: Vérification sur pièces et garde de publication

    @Test("Seuls les fichiers vérifiés sur pièces sortent ; une autre empreinte n'est pas vérifiée")
    func gate() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let root = "/lib"
        let (lu, nonLu) = try await db.pool.write { conn in
            let lu = try edition(conn, title: "Minima moralia", author: "Theodor W. Adorno", year: "1951", key: "Adorno1951Minima",
                                 path: "\(root)/Adorno.pdf", hash: "aaa")
            let nonLu = try edition(conn, title: "Dialektik der Aufklärung", author: "Max Horkheimer", year: "1944",
                                    key: "Horkheimer1944Dialektik", path: "\(root)/Horkheimer.pdf", hash: "bbb")
            try RetiredKey(key: "Wiesengrund1951Minima", editionId: lu.edition, replacedBy: "Adorno1951Minima", reason: "essai").insert(conn)
            return (lu, nonLu)
        }
        let store = CatalogStore(db: db)
        await #expect(throws: VerificationError.fingerprintMismatch(expected: "zzz", actual: "aaa")) {
            try await store.recordVerification(documentId: lu.document, readers: "Codex + Claude", proof: "p-1 : « Minima moralia »", expectedHash: "zzz")
        }
        await #expect(throws: VerificationError.noProof) {
            try await store.recordVerification(documentId: lu.document, readers: "Codex + Claude", proof: "  ")
        }
        try await store.recordVerification(documentId: lu.document, readers: "Codex + Claude", proof: "p-1 : « Minima moralia »", expectedHash: "AAA")
        let confiance = try await db.pool.read { try Document.fetchOne($0, key: lu.document)?.confidence }
        #expect(confiance == .high)

        let garde = PublicationRules(requireVerification: true)
        let (catalogue, report) = try await CatalogPublisher(db: db).build(root: root, rules: garde)
        #expect(catalogue.editions.map(\.key) == ["Adorno1951Minima"])
        #expect(catalogue.editions.first?.formerKeys == ["Wiesengrund1951Minima"])
        #expect(report.excludedUnverified == 1)
        #expect(try await CatalogPublisher(db: db).build(root: root, rules: PublicationRules()).0.editions.count == 2)

        // Le fichier a changé : la vérification ne vaut plus.
        try await db.pool.write { try $0.execute(sql: "UPDATE document SET contentHash = 'ccc' WHERE id = ?", arguments: [lu.document]) }
        #expect(try await CatalogPublisher(db: db).build(root: root, rules: garde).0.editions.isEmpty)
        _ = nonLu
    }
}
