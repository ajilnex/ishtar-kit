import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import IshtarCatalog
@testable import IshtarIngest

/// WP-34 — l'atelier d'un fonds confié : des copies de travail tirées du
/// dépôt, qui n'est jamais modifié ; des clés uniques dans tout kenosème.
@Suite("Atelier d'un fonds confié (WP-34)")
struct FondsAtelierTests {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-fonds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Chaque fichier du dossier, chemin relatif → contenu.
    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let base = dir.standardizedFileURL.path
        for case let url as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)! {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            files[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    @Test("Copies de travail : une par contenu, sans verrou, fiches Calibre comprises ; le dépôt intact")
    func copies() throws {
        let fonds = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fonds) }
        let recu = fonds.appendingPathComponent("recu"), fichiers = fonds.appendingPathComponent("fichiers")

        let livre = recu.appendingPathComponent("Philosophie/livre.epub")
        try FileManager.default.createDirectory(at: livre.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixtures.makeEPUB(at: livre, title: "Minima moralia", author: "Theodor W. Adorno", year: "1951", isbn13: nil,
                              bodyText: "La vie ne vit pas.")
        // Le même livre, ailleurs dans le dépôt.
        try FileManager.default.createDirectory(at: recu.appendingPathComponent("Divers"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: livre, to: recu.appendingPathComponent("Divers/copie.epub"))
        // Un EPUB sous verrou d'éditeur (Adobe).
        let verrou = recu.appendingPathComponent("Divers/verrou.epub")
        try Fixtures.makeEPUB(at: verrou, title: "Verrou", author: "Éditeur", year: "2020", isbn13: nil, bodyText: "Chiffré.")
        let archive = try Archive(url: verrou, accessMode: .update)
        let droits = Data("<rights/>".utf8)
        try archive.addEntry(with: "META-INF/rights.xml", type: .file, uncompressedSize: Int64(droits.count),
                             provider: { position, size in droits.subdata(in: Int(position) ..< Int(position) + size) })
        // Une bibliothèque Calibre : un livre et sa fiche.
        try write("Un texte libre.", to: recu.appendingPathComponent("Calibre/Wagner/La logique (12)/La logique - Wagner.txt"))
        try write("<package/>", to: recu.appendingPathComponent("Calibre/Wagner/La logique (12)/metadata.opf"))
        let avant = try snapshot(recu)

        let premier = try FondsAtelier.copyNew(from: recu, to: fichiers, known: [])
        #expect(premier.livres == 4)
        #expect(premier.copies == ["Calibre/Wagner/La logique (12)/La logique - Wagner.txt", "Divers/copie.epub"])
        #expect(premier.doublons == ["Philosophie/livre.epub"])
        #expect(premier.verrous == ["Divers/verrou.epub"])
        #expect(premier.compagnons == 1)
        #expect(try snapshot(fichiers).keys.sorted() == ["Calibre/Wagner/La logique (12)/La logique - Wagner.txt",
                                                        "Calibre/Wagner/La logique (12)/metadata.opf",
                                                        "Divers/copie.epub"])
        #expect(try snapshot(recu) == avant, "le dépôt n'est jamais modifié")

        // Second passage : les copies sont connues (renommées depuis, peut-être) ; rien n'est recopié.
        let known = Set(try LibraryScanner().scan(directory: fichiers).files.compactMap(\.contentHash))
        try FileManager.default.moveItem(at: fichiers.appendingPathComponent("Divers/copie.epub"),
                                         to: fichiers.appendingPathComponent("Divers/Adorno — Minima moralia (1951).epub"))
        let second = try FondsAtelier.copyNew(from: recu, to: fichiers, known: known)
        #expect(second.copies.isEmpty)
        #expect(second.dejaLa == 2)
        #expect(second.doublons == ["Philosophie/livre.epub"])
        #expect(second.compagnons == 0)
        #expect(try snapshot(recu) == avant)
    }

    @Test("Un nom déjà pris reçoit « [2] » ; une copie interrompue ne laisse rien")
    func nameTakenAndLeftovers() throws {
        let fonds = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fonds) }
        let recu = fonds.appendingPathComponent("recu"), fichiers = fonds.appendingPathComponent("fichiers")
        try write("nouveau", to: recu.appendingPathComponent("Adorno — Minima moralia (1951).txt"))
        try write("ancien, déjà rangé", to: fichiers.appendingPathComponent("Adorno — Minima moralia (1951).txt"))
        try write("tronqué", to: fichiers.appendingPathComponent(".Autre.txt.part"))
        // Un envoi que Rayons n'a pas fini de recevoir.
        try write("%PDF-1.4 la moitié d'un livre", to: recu.appendingPathComponent("Moitié.pdf.part"))

        let copie = try FondsAtelier.copyNew(from: recu, to: fichiers, known: [])
        #expect(copie.copies == ["Adorno — Minima moralia (1951).txt"])
        #expect(copie.incomplets == ["Moitié.pdf.part"])
        let contenu = try snapshot(fichiers)
        #expect(contenu.keys.sorted() == ["Adorno — Minima moralia (1951) [2].txt", "Adorno — Minima moralia (1951).txt"])
        #expect(contenu["Adorno — Minima moralia (1951) [2].txt"] == Data("nouveau".utf8))
        #expect(contenu["Adorno — Minima moralia (1951).txt"] == Data("ancien, déjà rangé".utf8))
    }

    @Test("De deux fichiers identiques, le mieux nommé est gardé")
    func bestNamedDuplicate() throws {
        let fonds = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fonds) }
        let recu = fonds.appendingPathComponent("recu"), fichiers = fonds.appendingPathComponent("fichiers")
        try write("Le même texte.", to: recu.appendingPathComponent("Divers/brassier copie.txt"))
        try write("Le même texte.", to: recu.appendingPathComponent("Philosophie/Brassier — Desubsumption (2024).txt"))
        let copie = try FondsAtelier.copyNew(from: recu, to: fichiers, known: [])
        #expect(copie.copies == ["Philosophie/Brassier — Desubsumption (2024).txt"])
        #expect(copie.doublons == ["Divers/brassier copie.txt"])
    }

    @Test("Le registre de Rayons se lit : identifiant, nom, état")
    func depot() throws {
        let fonds = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fonds) }
        try write(#"{"id":"yahor","nom":"Le fonds de Yahor","email":"y@x.fr","etat":"recu","fichiers":{},"envois":[]}"#,
                  to: fonds.appendingPathComponent("depot.json"))
        #expect(try FondsAtelier.depot(in: fonds) == FondsAtelier.Depot(id: "yahor", nom: "Le fonds de Yahor", etat: "recu"))
    }

    /// La fiche qu'écrit Calibre à côté de chaque livre.
    private let calibreOPF = """
        <?xml version='1.0' encoding='utf-8'?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:identifier opf:scheme="calibre" id="calibre_id">12</dc:identifier>
            <dc:identifier opf:scheme="uuid" id="uuid_id">1b9e2c41-77aa-4f0e-9d2b-5c3e1e0b7a11</dc:identifier>
            <dc:title>La logique</dc:title>
            <dc:creator opf:file-as="Wagner, Pierre" opf:role="aut">Pierre Wagner</dc:creator>
            <dc:contributor opf:file-as="calibre" opf:role="bkp">calibre (6.0.0) [https://calibre-ebook.com]</dc:contributor>
            <dc:date>2007-02-14T23:00:00+00:00</dc:date>
            <dc:publisher>Presses universitaires de France</dc:publisher>
            <dc:identifier opf:scheme="ISBN">9782130557640</dc:identifier>
            <dc:language>fra</dc:language>
          </metadata>
        </package>
        """

    @Test("Une fiche Calibre passe avant le nom de fichier et les métadonnées embarquées ; ailleurs, elle n'est pas lue")
    func calibreSidecar() throws {
        let racine = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: racine) }
        let dossier = racine.appendingPathComponent("Pierre Wagner/La logique (12)")
        let livre = dossier.appendingPathComponent("La logique - Pierre Wagner.epub")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        try Fixtures.makeEPUB(at: livre, title: "Titre embarqué", author: "Auteur embarqué", year: "1999", isbn13: nil)
        try write(calibreOPF, to: dossier.appendingPathComponent("metadata.opf"))
        try write("jpeg", to: dossier.appendingPathComponent("cover.jpg"))
        // Le même livre en deux formats : toujours un seul livre.
        try write("Le texte.", to: dossier.appendingPathComponent("La logique - Pierre Wagner.txt"))

        let guess = Ingestor.mechanicalGuess(fileName: livre.lastPathComponent, fileURL: livre, format: .epub)
        #expect(guess.title == "La logique")
        #expect(guess.author == "Pierre Wagner")
        #expect(guess.year == "2007")
        #expect(guess.isbn13 == "9782130557640")
        #expect(guess.language == "fr")
        #expect(guess.publisher == "Presses universitaires de France")
        #expect(guess.confidence == .structured)

        // Deux livres différents dans le dossier : la fiche ne dit pas lequel.
        try write("Un autre.", to: dossier.appendingPathComponent("Autre livre.txt"))
        #expect(EmbeddedMetadata.readCalibreSidecar(for: livre) == nil)
    }

    @Test("Les codes de langue des OPF : trois lettres, région")
    func languageCodes() {
        #expect(EmbeddedMetadata.languageCode("spa") == "es")
        #expect(EmbeddedMetadata.languageCode("ger") == "de")
        #expect(EmbeddedMetadata.languageCode("fr-FR") == "fr")
        #expect(EmbeddedMetadata.languageCode("EN") == "en")
    }

    /// Une édition, un document, sa clé.
    private func add(_ db: CatalogDatabase, title: String, author: String, year: String, hash: String,
                     isbn13: String? = nil) async throws -> UUID {
        try await db.pool.write { conn in
            let work = Work(title: title)
            try work.insert(conn)
            let creator = Creator(name: author)
            try creator.insert(conn)
            try WorkCreator(workId: work.id, creatorId: creator.id).insert(conn)
            let edition = Edition(workId: work.id, year: year, isbn13: isbn13)
            try edition.insert(conn)
            try Document(editionId: edition.id, filePath: "/fonds/fichiers/\(hash).pdf", originalFileName: "\(hash).pdf",
                         fileSize: 10, contentHash: hash, format: .pdf).insert(conn)
            try EditionKey.assignMissing(conn)
            return edition.id
        }
    }

    @Test("Clés entre fonds : la même édition garde la clé d'ailleurs, une autre en prend une libre, la main ne bouge pas")
    func keysAcrossFonds() async throws {
        let db = try CatalogDatabase(inMemory: ())
        let store = CatalogStore(db: db)
        let adorno = try await add(db, title: "Minima moralia", author: "Adorno", year: "1951", hash: "aaa")
        let badiou = try await add(db, title: "Éloge de l'amour", author: "Badiou", year: "2009", hash: "bbb")
        let freud = try await add(db, title: "Deuil et mélancolie", author: "Freud", year: "1917", hash: "ccc",
                                  isbn13: "9782228901307")
        let wagner = try await add(db, title: "La logique", author: "Wagner", year: "2007", hash: "ddd")
        try await store.setKey("Wagner2007Logique", forEdition: wagner)
        let avant = try await [adorno, badiou, freud].asyncMap { try await store.key(forEdition: $0)?.key }
        #expect(avant == ["Adorno1951Minima", "Badiou2009Eloge", "Freud1917Deuil"])

        let ailleurs: [String: OtherFondsKey] = [
            "Adorno1951Minima": OtherFondsKey(hashes: ["aaa"]),                        // le même fichier
            "Badiou2009Eloge": OtherFondsKey(hashes: ["zzz"]),                         // un autre livre
            "Freud1917Trauer": OtherFondsKey(hashes: ["yyy"], isbn13: "9782228901307"), // le même ISBN
            "Wagner2007Logique": OtherFondsKey(hashes: ["xxx"]),                       // clé manuelle ici
        ]
        let changes = try await store.separateKeys(from: ailleurs)
        #expect(changes.map { "\($0.from)→\($0.to)" } == ["Badiou2009Eloge→Badiou2009Eloge-b", "Freud1917Deuil→Freud1917Trauer"])
        #expect(try await store.key(forEdition: adorno)?.key == "Adorno1951Minima")
        #expect(try await store.key(forEdition: badiou)?.origin == .stable, "figée : les passes locales ne la rendent pas")
        #expect(try await store.key(forEdition: wagner)?.key == "Wagner2007Logique")
        #expect(try await store.separateKeys(from: ailleurs).isEmpty, "un second passage ne change rien")
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
