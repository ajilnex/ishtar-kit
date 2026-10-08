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
            try RetiredKey(key: "Wiesengrund_1951Minima", editionId: lu.edition, replacedBy: "Adorno1951Minima", reason: "essai").insert(conn)
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
        #expect(catalogue.editions.first?.formerKeys == ["Wiesengrund_1951Minima"])
        #expect(BibliographyExport.bibtex(catalogue.editions[0]).contains("ids = {Wiesengrund_1951Minima}"))
        #expect(report.excludedUnverified == 1)
        #expect(try await CatalogPublisher(db: db).build(root: root, rules: PublicationRules()).0.editions.count == 2)

        // Le fichier a changé : la vérification ne vaut plus.
        try await db.pool.write { try $0.execute(sql: "UPDATE document SET contentHash = 'ccc' WHERE id = ?", arguments: [lu.document]) }
        #expect(try await CatalogPublisher(db: db).build(root: root, rules: garde).0.editions.isEmpty)
        _ = nonLu
    }

    // MARK: Relecture du 07/10 : une clé retirée n'est jamais redonnée

    @Test("v10 : aucune écriture ne redonne à une autre édition une clé retirée ; setKey le dit")
    func retiredKeyNeverReused() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (a, b) = try await db.pool.write { conn in
            let a = try edition(conn, title: "Un", author: "A B", year: "2000", key: "B2000Un", path: "/lib/a.pdf", hash: "a").edition
            let b = try edition(conn, title: "Deux", author: "C D", year: "2001", key: "D2001Deux", path: "/lib/b.pdf", hash: "b").edition
            try RetiredKey(key: "Ancienne2000", editionId: a, replacedBy: "B2000Un", reason: "essai").insert(conn)
            return (a, b)
        }
        let store = CatalogStore(db: db)
        // setKey : refus net, casse ignorée.
        await #expect(throws: CiteKeyError.retired("ancienne2000")) { try await store.setKey("ancienne2000", forEdition: b) }
        // Les écritures directes (ancien binaire) sont arrêtées par les déclencheurs.
        await #expect(throws: DatabaseError.self) {
            try await db.pool.write { try EditionKey(editionId: b, key: "Ancienne2000", origin: .manual).save($0) }
        }
        await #expect(throws: DatabaseError.self) {
            try await db.pool.write { try $0.execute(sql: "UPDATE edition_key SET key = 'ANCIENNE2000' WHERE editionId = ?", arguments: [b]) }
        }
        #expect(try await store.key(forEdition: b)?.key == "D2001Deux")
        // La pierre de a n'a pas bougé.
        let pierre = try await db.pool.read { try RetiredKey.fetchOne($0, key: "Ancienne2000") }
        #expect(pierre?.editionId == a)

        // L'édition d'origine peut reprendre sa clé : la pierre est levée, la clé est vivante.
        try await store.setKey("Ancienne2000", forEdition: a)
        #expect(try await store.key(forEdition: a)?.key == "Ancienne2000")
        let restes = try await db.pool.read { try RetiredKey.order(Column("key")).fetchAll($0).map(\.key) }
        #expect(restes == ["B2000Un"])   // celle que le changement vient d'écrire
        #expect(try await store.retiredKeysByEdition()[a] == ["B2000Un"])
    }

    @Test("Le remplacement n'écrase pas une pierre existante")
    func replaceKeepsExistingStone() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let e = try await db.pool.write { conn -> UUID in
            let e = try edition(conn, title: "Lettres", author: "Pline le Jeune", year: "100", key: "Jeune100Lettres",
                                path: "/lib/p.pdf", hash: "p").edition
            // Pierre déjà là pour la même clé (reprise de sa propre ancienne clé, puis nouveau changement).
            try RetiredKey(key: "Jeune100Lettres", editionId: e, replacedBy: nil, reason: "première raison",
                           dateRetired: Date(timeIntervalSince1970: 0)).insert(conn)
            return e
        }
        let store = CatalogStore(db: db)
        _ = try await store.replaceKeys(editionIds: [e], reason: "seconde raison", dryRun: false)
        let pierre = try #require(try await db.pool.read { try RetiredKey.fetchOne($0, key: "Jeune100Lettres") })
        #expect(pierre.editionId == e)
        #expect(pierre.reason == "première raison")
        #expect(pierre.replacedBy == "PlineLeJeune100Lettres")
    }

    @Test("Une clé figée changée par UPDATE laisse sa pierre (setKey, séparation des fonds) ; une provisoire, non")
    func updateLeavesStone() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (a, b, c) = try await db.pool.write { conn in
            let a = try edition(conn, title: "Un", author: "A B", year: "2000", key: "B2000Un", origin: .stable, path: "/lib/a.pdf", hash: "ha").edition
            let b = try edition(conn, title: "Deux", author: "C D", year: "2001", key: "D2001Deux", origin: .stable, path: "/lib/b.pdf", hash: "hb").edition
            let c = try edition(conn, title: "Trois", author: "E F", year: "2002", key: "F2002Trois", origin: .generated, path: "/lib/c.pdf", hash: "hc").edition
            return (a, b, c)
        }
        let store = CatalogStore(db: db)
        try await store.setKey("Un2000Choisie", forEdition: a)
        try await store.setKey("Trois2002Choisie", forEdition: c)   // provisoire : jamais sortie
        var pierres = try await db.pool.read { try RetiredKey.order(Column("key")).fetchAll($0) }
        #expect(pierres.map(\.key) == ["B2000Un"])
        #expect(pierres.first?.editionId == a && pierres.first?.replacedBy == "Un2000Choisie")

        // Un second changement : la chaîne suit, sans doublon.
        try await store.setKey("Un2000Dernière".folding(options: .diacriticInsensitive, locale: nil), forEdition: a)
        pierres = try await db.pool.read { try RetiredKey.order(Column("key")).fetchAll($0) }
        #expect(pierres.map(\.key) == ["B2000Un", "Un2000Choisie"])
        #expect(pierres.allSatisfy { $0.replacedBy == "Un2000Derniere" })

        // Séparation des fonds : la clé d'un autre fonds est prise, b reçoit une clé libre et laisse sa pierre.
        let changes = try await store.separateKeys(from: ["D2001Deux": OtherFondsKey(hashes: ["zzz"])])
        #expect(changes.count == 1)
        let nouvelle = try #require(try await store.key(forEdition: b)?.key)
        #expect(nouvelle != "D2001Deux")
        let pierreB = try await db.pool.read { try RetiredKey.fetchOne($0, key: "D2001Deux") }
        #expect(pierreB?.editionId == b && pierreB?.replacedBy == nouvelle)
        // Une simple différence de casse ne laisse rien.
        try await db.pool.write { try $0.execute(sql: "UPDATE edition_key SET key = 'UN2000DERNIERE' WHERE editionId = ?", arguments: [a]) }
        #expect(try await db.pool.read { try RetiredKey.fetchOne($0, key: "UN2000DERNIERE") } == nil)
    }

    @Test("La séparation des fonds ne choisit jamais une clé retirée")
    func separationAvoidsStones() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let b = try await db.pool.write { conn -> UUID in
            // « D2001Deux-b » est déjà une pierre d'une autre édition : la séparation doit passer à « -c ».
            try RetiredKey(key: "D2001Deux-b", editionId: UUID(), replacedBy: nil, reason: "essai").insert(conn)
            return try edition(conn, title: "Deux", author: "C D", year: "2001", key: "D2001Deux", origin: .stable, path: "/lib/b.pdf", hash: "hb").edition
        }
        let store = CatalogStore(db: db)
        try await store.separateKeys(from: ["D2001Deux": OtherFondsKey(hashes: ["zzz"])])
        let k = try #require(try await store.key(forEdition: b)?.key)
        #expect(k != "D2001Deux" && k.lowercased() != "d2001deux-b")
    }

    @Test("La publication n'annonce jamais comme ancienne une clé vivante")
    func formerKeyNeverLive() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (a, b) = try await db.pool.write { conn in
            let a = try edition(conn, title: "Un", author: "A B", year: "2000", key: "B2000Un", path: "/lib/a.pdf", hash: "a").edition
            let b = try edition(conn, title: "Deux", author: "C D", year: "2001", key: "D2001Deux", path: "/lib/b.pdf", hash: "b").edition
            return (a, b)
        }
        // Base d'un ancien binaire : on contourne les déclencheurs pour fabriquer l'incohérence.
        try await db.pool.write { conn in
            try conn.execute(sql: "DROP TRIGGER edition_key_unretire_on_insert")
            try RetiredKey(key: "d2001deux", editionId: a, replacedBy: "B2000Un", reason: "essai").insert(conn)
            try RetiredKey(key: "Vraie-ancienne", editionId: a, replacedBy: "B2000Un", reason: "essai").insert(conn)
        }
        let parEdition = try await CatalogStore(db: db).retiredKeysByEdition()
        #expect(parEdition[a] == ["Vraie-ancienne"])
        #expect(parEdition[b] == nil)
    }

    @Test("La copie réduite ne garde que les pierres des éditions publiées")
    func reducedCopyPrunesStones() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ishtar-reduce-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("catalog.sqlite")
        let db = try CatalogDatabase(at: url)
        try await db.pool.write { conn in
            let pub = try edition(conn, title: "Un", author: "A B", year: "2000", key: "B2000Un", path: "/lib/a.pdf", hash: "pub").edition
            let prive = try edition(conn, title: "Journal", author: "C D", year: "2001", key: "D2001Journal", path: "/lib/_NON_BIBLIO/j.pdf", hash: "prive").edition
            try RetiredKey(key: "Ancienne-pub", editionId: pub, replacedBy: "B2000Un", reason: "essai").insert(conn)
            try RetiredKey(key: "Ancienne-prive", editionId: prive, replacedBy: "D2001Journal", reason: "essai").insert(conn)
        }
        let copie = tmp.appendingPathComponent("copie.sqlite")
        try await db.pool.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [copie.path]) }
        try CatalogPublisher.reduce(snapshotAt: copie, keeping: ["pub"])
        let q = try DatabaseQueue(path: copie.path)
        let (cles, pierres) = try await q.read { conn in
            (try String.fetchAll(conn, sql: "SELECT key FROM edition_key ORDER BY key"),
             try String.fetchAll(conn, sql: "SELECT key FROM edition_key_retired ORDER BY key"))
        }
        #expect(cles == ["B2000Un"])
        #expect(pierres == ["Ancienne-pub"])   // ni « supprimée » pour le privé, ni sa pierre
    }

    // MARK: Relecture du 08/10

    @Test("proofRefusal : preuve et sha256 obligatoires, empreinte égale, avant toute écriture")
    func proofRefusal() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let doc = try await db.pool.write { try edition($0, title: "Un", author: "A B", year: "2000", key: "B2000Un", path: "/lib/a.pdf", hash: "abc").document }
        let store = CatalogStore(db: db)
        #expect(try await store.proofRefusal(documentId: doc, proof: nil, sha256: "abc") == "preuve manquante")
        #expect(try await store.proofRefusal(documentId: doc, proof: " ", sha256: "abc") == "preuve manquante")
        #expect(try await store.proofRefusal(documentId: doc, proof: "p-1", sha256: nil) == "sha256 manquant")
        #expect(try await store.proofRefusal(documentId: doc, proof: "p-1", sha256: "  ") == "sha256 manquant")
        #expect(try await store.proofRefusal(documentId: doc, proof: "p-1", sha256: "deadbeef") == "empreinte différente")
        #expect(try await store.proofRefusal(documentId: doc, proof: "p-1", sha256: "ABC") == nil)
    }

    @Test("detach : refusé pour le dernier fichier d'une édition à clé figée, permis sinon")
    func detachGuard() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (seul, double1, simple) = try await db.pool.write { conn -> (UUID, UUID, UUID) in
            let seul = try edition(conn, title: "Un", author: "A B", year: "2000", key: "B2000Un", path: "/lib/a.pdf", hash: "a").document
            let d = try edition(conn, title: "Deux", author: "C D", year: "2001", key: "D2001Deux", path: "/lib/b.pdf", hash: "b")
            try Document(editionId: d.edition, filePath: "/lib/b2.pdf", originalFileName: "b2.pdf", fileSize: 10, contentHash: "b2",
                         format: .pdf, curationStatus: .recognized).insert(conn)
            let p = try edition(conn, title: "Trois", author: "E F", year: "2002", key: "F2002Trois", origin: .generated, path: "/lib/c.pdf", hash: "c").document
            return (seul, d.document, p)
        }
        let store = CatalogStore(db: db)
        await #expect(throws: DatabaseError.self) { try await store.detach(documentId: seul) }
        try await store.detach(documentId: double1)
        try await store.detach(documentId: simple)
        let ed = try await db.pool.read { try Document.fetchOne($0, key: seul)?.editionId }
        #expect(try await store.key(forEdition: #require(ed))?.key == "B2000Un")
    }

    @Test("Le déclencheur BEFORE INSERT refuse, par un vrai INSERT, une clé retirée d'une autre édition")
    func beforeInsertTrigger() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (a, neuve) = try await db.pool.write { conn -> (UUID, UUID) in
            let a = try edition(conn, title: "Un", author: "A B", year: "2000", key: "B2000Un", path: "/lib/a.pdf", hash: "a").edition
            let neuve = try edition(conn, title: "Deux", author: "C D", year: "2001", path: "/lib/b.pdf", hash: "b").edition   // sans clé
            try RetiredKey(key: "Ancienne2000", editionId: a, replacedBy: "B2000Un", reason: "essai").insert(conn)
            return (a, neuve)
        }
        do {
            try await db.pool.write { try $0.execute(sql: "INSERT INTO edition_key (editionId, key, origin, dateAssigned) VALUES (?, 'ANCIENNE2000', 'manual', datetime('now'))", arguments: [neuve]) }
            Issue.record("l'INSERT aurait dû être refusé")
        } catch let error as DatabaseError {
            #expect(error.message?.contains("clé retirée") == true)
        }
        #expect(try await db.pool.read { try EditionKey.fetchOne($0, key: neuve) } == nil)
        // L'édition d'origine, elle, peut la reprendre par INSERT.
        try await db.pool.write { conn in
            try conn.execute(sql: "DELETE FROM edition_key WHERE editionId = ?", arguments: [a])
            try conn.execute(sql: "INSERT INTO edition_key (editionId, key, origin, dateAssigned) VALUES (?, 'Ancienne2000', 'manual', datetime('now'))", arguments: [a])
        }
        #expect(try await CatalogStore(db: db).key(forEdition: a)?.key == "Ancienne2000")
    }

    @Test("Deux passages de séparation des fonds réussissent, avec des pierres ; la branche « même édition » aussi")
    func twoSeparationPasses() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let (b, c) = try await db.pool.write { conn -> (UUID, UUID) in
            let b = try edition(conn, title: "Deux", author: "C D", year: "2001", key: "D2001Deux", origin: .stable, path: "/lib/b.pdf", hash: "hb").edition
            let c = try edition(conn, title: "Trois", author: "E F", year: "2002", key: "F2002Trois", origin: .stable, path: "/lib/c.pdf", hash: "hc").edition
            return (b, c)
        }
        let store = CatalogStore(db: db)
        let ailleurs: [String: OtherFondsKey] = [
            "D2001Deux": OtherFondsKey(hashes: ["zzz"]),            // autre livre : b reçoit une clé libre
            "F2002TroisAilleurs": OtherFondsKey(hashes: ["hc"]),    // même fichier que c : c prend cette clé
        ]
        let un = try await store.separateKeys(from: ailleurs)
        #expect(un.count == 2)
        let deux = try await store.separateKeys(from: ailleurs)   // plus de « SQLite error 19 »
        #expect(deux.isEmpty)
        #expect(try await store.key(forEdition: c)?.key == "F2002TroisAilleurs")
        let pierres = try await db.pool.read { try RetiredKey.fetchAll($0).map { $0.key.lowercased() }.sorted() }
        #expect(pierres == ["d2001deux", "f2002trois"])
        let k = try #require(try await store.key(forEdition: b)?.key)
        #expect(k != "D2001Deux")
    }
}
