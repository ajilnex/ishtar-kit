import ArgumentParser
import Foundation
import GRDB
import IshtarCatalog
import IshtarIngest
import IshtarSearch

// MARK: - L'atelier d'un fonds confié (WP-34)

/// Sur le serveur : du dépôt qu'un contributeur a confié à Rayons
/// (`<fonds>/depot.json`, `recu/`) au catalogue publié du fonds. Les étapes
/// sont celles d'ajîl sur le Mac — catalogue, texte, clés, noms, publication —
/// sur des copies de travail (`fichiers/`) ; le dépôt reste tel qu'envoyé.
/// Rien n'est mis en ligne ici : la revue d'Aubin en décide.
struct Fonds: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "L'atelier d'un fonds confié (serveur) : copies de travail, catalogue, noms, clés, publication."
    )

    @Argument(help: "Le dossier du fonds (…/Fonds/<id>), avec depot.json et recu/.", transform: URL.init(fileURLWithPath:))
    var dossier: URL

    @Option(name: .long, help: "La liste des fonds publiés (fonds.json de kenosème) : leurs clés ne sont jamais reprises.")
    var autres: String = "\(NSHomeDirectory())/.config/kenoseme/fonds.json"

    @Flag(name: .long, help: "Travaille même si l'envoi n'est pas fini (essai).")
    var force = false

    func run() async throws {
        let fm = FileManager.default
        let depot = try FondsAtelier.depot(in: dossier)
        guard depot.etat == "recu" || (force && depot.etat == "envoi") else {
            print("Fonds « \(depot.nom) » : \(depot.etat == "retire" ? "retiré" : "envoi en cours") — l'atelier attend.")
            return
        }
        let recu = dossier.appendingPathComponent("recu", isDirectory: true)
        let fichiers = dossier.appendingPathComponent("fichiers", isDirectory: true)
        let atelier = dossier.appendingPathComponent("catalogue", isDirectory: true)
        let publication = dossier.appendingPathComponent("publication", isDirectory: true)
        let vignettes = atelier.appendingPathComponent("vignettes", isDirectory: true)
        try fm.createDirectory(at: vignettes, withIntermediateDirectories: true)

        // Un seul atelier à la fois sur un fonds ; le verrou tombe avec le processus.
        let verrou = open(atelier.appendingPathComponent(".atelier.lock").path, O_CREAT | O_WRONLY, 0o644)
        guard verrou >= 0, flock(verrou, LOCK_EX | LOCK_NB) == 0 else {
            print("Un atelier travaille déjà sur « \(depot.nom) ».")
            return
        }
        defer { close(verrou) }

        print("Atelier du fonds « \(depot.nom) » (\(depot.id))")
        print(String(repeating: "─", count: 60))
        let dbURL = atelier.appendingPathComponent("catalog.sqlite")
        let database = try CatalogDatabase(at: dbURL)
        let store = CatalogStore(db: database)

        // 1. Les copies de travail : les livres nouveaux du dépôt.
        let known = Set(try await database.pool.read {
            try String.fetchAll($0, sql: "SELECT contentHash FROM document WHERE contentHash IS NOT NULL")
        })
        let copie = try FondsAtelier.copyNew(from: recu, to: fichiers, known: known)
        print("Livres reçus             \(copie.livres)")
        print("  copiés à ce passage    \(copie.copies.count)")
        print("  doublons écartés       \(copie.doublons.count)")
        print("  verrouillés (DRM)      \(copie.verrous.count)")
        if !copie.incomplets.isEmpty { print("  envois inachevés       \(copie.incomplets.count)") }

        // 2. Le catalogue du fonds, puis le texte.
        let ingestion = try Ingestor().ingest(report: LibraryScanner().scan(directory: fichiers),
                                              sourceFolder: fichiers, into: database)
        if ingestion.isScanIncomplete { throw FondsAtelier.AtelierError.scan(ingestion.scanErrorMessage ?? fichiers.path) }
        let extraits = try await ExtractionPipeline().extractAllPending(into: database)
        print("Catalogue                \(ingestion.scanned) documents (\(ingestion.added) nouveaux), \(extraits) textes extraits")

        // 3. Les clés : une clé ne désigne qu'une édition dans tout kenosème.
        try await store.assignMissingKeys()
        let cles = try await store.separateKeys(from: try Self.foreignKeys(listedIn: autres, besides: dossier))
        for change in cles { print("  clé \(change.from) → \(change.to)") }

        // 4. Les noms selon les normes, pour les fiches sûres ; un journal pour défaire.
        let journal = atelier.appendingPathComponent("ranger.tsv").path
        let avant = Self.lines(of: journal)
        let ranger = try Ranger.parse(["--db", dbURL.path, "--racine", fichiers.path, "--appliquer", "--journal", journal])
        try await ranger.run()
        let renommes = Self.lines(of: journal) - avant

        // Le donateur a pu retirer son fonds pendant ce temps : rien ne doit survivre.
        if retiredMeanwhile() { return }

        // 5. La publication du fonds (hors ligne tant que la revue n'a pas eu lieu).
        let report = try await CatalogPublisher(db: database).publish(
            root: fichiers.path, rules: PublicationRules(excludedFolders: ["_NON_BIBLIO/"]), to: publication,
            coversFolder: vignettes, includeCorpus: true, fonds: PublishedFonds(id: depot.id, nom: depot.nom),
            renderCover: { @Sendable url in await CoverRenderer.png(for: url, strictness: 0.5) })

        if retiredMeanwhile() { return }

        // 6. Le bilan, pour la revue et pour le donateur.
        let racine = fichiers.standardizedFileURL.path + "/"
        let (catalogues, aRevoir) = try await database.pool.read { conn in
            let total = try Int.fetchOne(conn, sql: "SELECT count(*) FROM document WHERE isMissing = 0") ?? 0
            let incertains = try Row.fetchAll(conn, sql: """
                SELECT d.filePath AS path, COALESCE(NULLIF(e.title, ''), w.title) AS title,
                       (SELECT group_concat(c.name, ' & ') FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                         WHERE wc.workId = w.id AND wc.role = 'author') AS authors
                FROM document d JOIN edition e ON e.id = d.editionId JOIN work w ON w.id = e.workId
                WHERE d.isMissing = 0 AND w.confidence = 'low' ORDER BY d.filePath
                """).map { row -> FondsAtelier.ARevoir in
                    let path: String = row["path"]
                    return FondsAtelier.ARevoir(chemin: path.hasPrefix(racine) ? String(path.dropFirst(racine.count)) : path,
                                                titre: row["title"], auteurs: row["authors"])
                }
            return (total, incertains)
        }
        let bilan = FondsAtelier.Bilan(fonds: depot.id, nom: depot.nom, fait: Date(), copie: copie, catalogues: catalogues,
                                       aRevoir: aRevoir, renommes: renommes,
                                       cles: cles.map { FondsAtelier.CleChangee(avant: $0.from, apres: $0.to) },
                                       publies: report.editions, couvertures: report.covers)
        try bilan.write(to: atelier.appendingPathComponent("atelier.json"))
        print(String(repeating: "─", count: 60))
        print("Renommés                 \(renommes)")
        print("À revoir                 \(aRevoir.count)")
        print("Publiés                  \(report.editions) éditions, \(report.covers) couvertures → \(publication.path)")
    }

    /// Retiré pendant l'atelier ? Ce que l'atelier a produit s'efface alors aussi.
    func retiredMeanwhile() -> Bool {
        guard (try? FondsAtelier.depot(in: dossier))?.etat == "retire" else { return false }
        for nom in ["fichiers", "catalogue", "publication"] {
            try? FileManager.default.removeItem(at: dossier.appendingPathComponent(nom))
        }
        print("Fonds retiré pendant l'atelier : ce qu'il avait produit est effacé.")
        return true
    }

    /// Les clés des autres fonds : ceux de la liste publiée (fonds.json), puis
    /// les fonds voisins (publiés hors ligne). Une liste ou un catalogue
    /// absents ne bloquent rien ; on le dit.
    static func foreignKeys(listedIn list: String, besides fonds: URL) throws -> [String: OtherFondsKey] {
        struct Entry: Decodable { let publication: String }
        let own = fonds.appendingPathComponent("publication").standardizedFileURL.path
        var publications: [String] = []
        if let data = FileManager.default.contents(atPath: list) {
            publications += try JSONDecoder().decode([Entry].self, from: data).map(\.publication)
        } else {
            print("⚠️ Liste des fonds introuvable : \(list)")
        }
        let voisins = fonds.deletingLastPathComponent()
        for nom in (try? FileManager.default.contentsOfDirectory(atPath: voisins.path))?.sorted() ?? [] {
            publications.append(voisins.appendingPathComponent(nom).appendingPathComponent("publication").path)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var keys: [String: OtherFondsKey] = [:]
        for publication in Set(publications.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).sorted() where publication != own {
            let url = URL(fileURLWithPath: publication).appendingPathComponent("catalogue.json")
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let catalogue = try? decoder.decode(PublishedCatalogue.self, from: data) else {
                print("⚠️ Catalogue illisible : \(url.path)")
                continue
            }
            for edition in catalogue.editions where keys[edition.key] == nil {
                keys[edition.key] = OtherFondsKey(hashes: Set(edition.files.map(\.sha256)), isbn13: edition.isbn13)
            }
        }
        return keys
    }

    static func lines(of path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }
}
