import Foundation
import GRDB
import IshtarCatalog

/// Le catalogue publié : un instantané ouvert, lisible sans Ishtar, que
/// d'autres outils consomment (site de consultation, bibliographie, serveur).
///
/// Format documenté dans `SCHEMA.md` (« Catalogue publié »). Les chemins sont
/// **relatifs** à la racine de la bibliothèque : l'instantané reste valable
/// sur une autre machine qui détient une copie des mêmes fichiers.
public struct PublishedCatalogue: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public var version: Int
    public var generatedAt: Date
    /// Nom du dossier de la bibliothèque (jamais son chemin absolu).
    public var library: String
    /// Le fonds : de qui vient cette bibliothèque (provenance). Facultatif.
    public var fonds: PublishedFonds?
    public var editions: [PublishedEdition]
}

/// La provenance d'une bibliothèque publiée : un identifiant court et stable
/// (« aj »), et le nom sous lequel le fonds se présente.
public struct PublishedFonds: Codable, Sendable, Equatable {
    public var id: String
    public var nom: String

    public init(id: String, nom: String) {
        self.id = id
        self.nom = nom
    }
}

public struct PublishedEdition: Codable, Sendable, Equatable {
    public var key: String
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    /// Les mêmes auteurs, avec forme de classement et notices (lot F, v8).
    public var people: [PublishedPerson]?
    /// Année de l'œuvre.
    public var year: String?
    /// Année de cette édition, quand elle diffère de celle de l'œuvre.
    public var editionYear: String?
    public var publisher: String?
    public var language: String?
    public var isbn13: String?
    public var doi: String?
    public var discipline: String?
    /// Chemins des collections, du général au particulier (« inventaire/01 - Sources primaires »).
    public var collections: [String]
    public var status: String
    public var confidence: String
    public var dateAdded: Date
    public var files: [PublishedFile]
}

/// Un auteur, avec sa forme de classement et ses notices d'autorité
/// confirmées (NORMES §6 : « Prénom Nom » pour présenter, « Nom, Prénom »
/// pour classer).
public struct PublishedPerson: Codable, Sendable, Equatable {
    public var name: String
    public var sortName: String?
    public var idref: String?
    public var bnf: String?
    public var wikidata: String?

    public init(name: String, sortName: String? = nil, idref: String? = nil, bnf: String? = nil, wikidata: String? = nil) {
        self.name = name
        self.sortName = sortName
        self.idref = idref
        self.bnf = bnf
        self.wikidata = wikidata
    }
}

public struct PublishedFile: Codable, Sendable, Equatable {
    public var sha256: String
    /// Chemin relatif à la racine de la bibliothèque.
    public var path: String
    public var format: String
    public var size: Int64
}

/// Ce qui ne doit pas sortir de la machine. Les règles viennent de
/// l'utilisateur : Ishtar ne présume pas de ce qui est privé chez lui.
public struct PublicationRules: Sendable, Equatable {
    /// Dossiers (relatifs à la racine) dont rien n'est publié, sous-dossiers compris.
    public var excludedFolders: [String]
    /// Préfixes de titre d'œuvre écartés (fiches en attente de tri, par exemple).
    public var excludedTitlePrefixes: [String]

    public init(excludedFolders: [String] = [], excludedTitlePrefixes: [String] = []) {
        self.excludedFolders = excludedFolders.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        self.excludedTitlePrefixes = excludedTitlePrefixes
    }

    func excludes(relativePath: String) -> Bool {
        excludedFolders.contains { folder in
            relativePath == folder || relativePath.hasPrefix(folder + "/")
        }
    }

    func excludes(title: String) -> Bool {
        excludedTitlePrefixes.contains { title.hasPrefix($0) }
    }
}

public struct PublicationReport: Sendable, Equatable {
    public var editions = 0
    public var files = 0
    public var covers = 0
    public var excludedByRule = 0
    public var excludedMissingOrIgnored = 0
    /// Vrai si le manifeste existant disait déjà la même chose : il n'a pas
    /// été réécrit (rien à transporter, rien à recharger côté serveur).
    public var unchanged = false
}

public struct CatalogPublisher: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    /// Construit le catalogue publié, sans rien écrire. Pur à base donnée.
    ///
    /// Un document n'est publié que s'il est présent, non ignoré, pourvu d'une
    /// empreinte (c'est par elle qu'on le télécharge), rangé sous la racine,
    /// et hors des exclusions. Une même empreinte n'est publiée qu'une fois.
    public func build(root: String, rules: PublicationRules, fonds: PublishedFonds? = nil,
                      now: Date = Date()) async throws -> (PublishedCatalogue, PublicationReport) {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        let rows = try await LibraryOverview(db: db).rows()

        let (keys, collectionPaths, people) = try await db.pool.read { conn -> ([UUID: String], [UUID: [String]], [UUID: [PublishedPerson]]) in
            var keys: [UUID: String] = [:]
            for key in try EditionKey.fetchAll(conn) { keys[key.editionId] = key.key }
            var links: [UUID: [String: String]] = [:]
            for link in try AuthorityLink.filter(Column("entityType") == AuthorityLink.EntityType.creator
                                                 && Column("status") == AuthorityLink.Status.confirmed).fetchAll(conn) {
                links[link.entityId, default: [:]][link.scheme.rawValue] = link.identifier
            }
            var people: [UUID: [PublishedPerson]] = [:]
            for row in try Row.fetchAll(conn, sql: """
                SELECT wc.workId AS workId, c.id AS id, c.name AS name, c.sortName AS sortName
                FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                WHERE wc.role = 'author' ORDER BY wc.workId, wc.position
                """) {
                let id: UUID = row["id"]
                let l = links[id] ?? [:]
                people[row["workId"], default: []].append(PublishedPerson(
                    name: row["name"], sortName: row["sortName"], idref: l["idref"], bnf: l["bnf"], wikidata: l["wikidata"]))
            }
            var paths: [UUID: [String]] = [:]
            for row in try Row.fetchAll(conn, sql: """
                SELECT ci.workId AS workId, c.sourceFolderPath AS path, c.name AS name
                FROM collection_item ci JOIN collection c ON c.id = ci.collectionId
                """) {
                let workId: UUID = row["workId"]
                let path: String? = row["path"]
                let name: String = row["name"]
                paths[workId, default: []].append(path ?? name)
            }
            return (keys, paths, people)
        }

        var report = PublicationReport()
        var seenHashes: Set<String> = []
        var editions: [UUID: PublishedEdition] = [:]
        var order: [UUID] = []

        for row in rows {
            let document = row.document
            guard let edition = row.edition else { continue }
            guard !document.isMissing, document.curationStatus != .ignored else {
                report.excludedMissingOrIgnored += 1
                continue
            }
            guard let relative = Self.relativePath(document.filePath, root: rootPath),
                  let hash = document.contentHash, !hash.isEmpty
            else { continue }
            if rules.excludes(relativePath: relative) || rules.excludes(title: row.work.title) {
                report.excludedByRule += 1
                continue
            }
            guard seenHashes.insert(hash).inserted, let key = keys[edition.id] else { continue }

            let file = PublishedFile(sha256: hash, path: relative,
                                     format: document.format.rawValue, size: document.fileSize)
            if editions[edition.id] != nil {
                editions[edition.id]?.files.append(file)
                continue
            }
            let workYear = row.work.date
            editions[edition.id] = PublishedEdition(
                key: key,
                title: edition.title ?? row.work.title,
                subtitle: row.work.subtitle,
                authors: row.authors,
                people: people[row.work.id].flatMap { $0.isEmpty ? nil : $0 },
                year: workYear ?? edition.year,
                editionYear: (workYear != nil && edition.year != workYear) ? edition.year : nil,
                publisher: edition.publisher,
                language: edition.language,
                isbn13: edition.isbn13,
                doi: edition.doi,
                discipline: row.work.discipline,
                collections: (collectionPaths[row.work.id] ?? [])
                    .filter { !rules.excludes(relativePath: $0) }.sorted(),
                status: edition.curationStatus.rawValue,
                confidence: edition.confidence.rawValue,
                dateAdded: document.dateAdded,
                files: [file]
            )
            order.append(edition.id)
        }

        let published = order.compactMap { editions[$0] }
        report.editions = published.count
        report.files = published.reduce(0) { $0 + $1.files.count }
        let catalogue = PublishedCatalogue(
            version: PublishedCatalogue.formatVersion,
            generatedAt: now,
            library: URL(fileURLWithPath: rootPath).lastPathComponent,
            fonds: fonds,
            editions: published
        )
        return (catalogue, report)
    }

    /// Écrit la publication dans `outputFolder` :
    /// `catalogue.json`, `covers/<sha256>.png` (copiées depuis `coversFolder`
    /// si fourni), `catalog.sqlite` (copie réduite aux documents publiés).
    ///
    /// Chaque fichier est écrit à côté puis mis en place par renommage, et le
    /// manifeste `catalogue.json` en dernier : un lecteur ne voit jamais un
    /// catalogue qui annonce des couvertures ou une base pas encore là.
    ///
    /// `renderCover` fabrique la couverture qui manque au cache (chemin absolu
    /// du fichier → PNG). `includeDatabase` : la base réduite porte les textes
    /// intégraux, lourde à transporter ; seulement quand un outil en a besoin.
    @discardableResult
    public func publish(root: String, rules: PublicationRules, to outputFolder: URL,
                        coversFolder: URL? = nil, includeDatabase: Bool = false, fonds: PublishedFonds? = nil,
                        renderCover: (@Sendable (URL) async -> Data?)? = nil,
                        now: Date = Date()) async throws -> PublicationReport {
        let fm = FileManager.default
        try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let (catalogue, built) = try await build(root: root, rules: rules, fonds: fonds, now: now)
        var report = built

        // 1. Base réduite, pour la recherche plein texte côté serveur.
        let sqliteTarget = outputFolder.appendingPathComponent("catalog.sqlite")
        if includeDatabase {
            let sqliteTemp = outputFolder.appendingPathComponent(".catalog.sqlite.tmp")
            try? fm.removeItem(at: sqliteTemp)
            try await db.pool.writeWithoutTransaction { conn in
                try conn.execute(sql: "VACUUM INTO ?", arguments: [sqliteTemp.path])
            }
            try Self.reduce(snapshotAt: sqliteTemp,
                            keeping: Set(catalogue.editions.flatMap { $0.files.map(\.sha256) }))
            if fm.fileExists(atPath: sqliteTarget.path) {
                _ = try fm.replaceItemAt(sqliteTarget, withItemAt: sqliteTemp)
            } else {
                try fm.moveItem(at: sqliteTemp, to: sqliteTarget)
            }
        } else {
            try? fm.removeItem(at: sqliteTarget)
        }

        // 2. Couvertures : ajout des manquantes, retrait des orphelines.
        let coversOut = outputFolder.appendingPathComponent("covers", isDirectory: true)
        try fm.createDirectory(at: coversOut, withIntermediateDirectories: true)
        var wanted: Set<String> = []
        let rootURL = URL(fileURLWithPath: root)
        for edition in catalogue.editions {
            for file in edition.files {
                let name = "\(file.sha256).png"
                let target = coversOut.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) {
                    wanted.insert(name)
                    continue
                }
                if let source = coversFolder?.appendingPathComponent(name),
                   fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: target)
                    wanted.insert(name)
                } else if let renderCover,
                          let data = await renderCover(rootURL.appendingPathComponent(file.path)) {
                    try data.write(to: target, options: .atomic)
                    wanted.insert(name)
                }
            }
        }
        for existing in (try? fm.contentsOfDirectory(atPath: coversOut.path)) ?? []
        where existing.hasSuffix(".png") && !wanted.contains(existing) {
            try fm.removeItem(at: coversOut.appendingPathComponent(existing))
        }
        report.covers = wanted.count

        // 3. Le manifeste, en dernier — et seulement s'il a changé : une
        // publication régulière ne doit rien transporter quand rien n'a bougé.
        // On compare le texte même du fichier (les dates ISO 8601 perdent leurs
        // fractions de seconde : comparer des valeurs relues serait faux).
        let manifest = outputFolder.appendingPathComponent("catalogue.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let existing = try? Data(contentsOf: manifest),
           let old = try? decoder.decode(PublishedCatalogue.self, from: existing) {
            var same = catalogue
            same.generatedAt = old.generatedAt
            if try encoder.encode(same) == existing {
                report.unchanged = true
                return report
            }
        }
        let data = try encoder.encode(catalogue)
        try data.write(to: manifest, options: .atomic)
        return report
    }

    /// Chemin relatif à la racine, ou nil si le document est ailleurs.
    static func relativePath(_ path: String, root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Réduit une copie du catalogue aux documents publiés : rien de ce qui a
    /// été écarté (dossiers privés, fichiers ignorés) ne quitte la machine,
    /// pas même son texte. Les conversations du démon restent aussi chez soi.
    static func reduce(snapshotAt url: URL, keeping hashes: Set<String>) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.inDatabase { conn in
            try conn.execute(sql: "PRAGMA foreign_keys = ON")
            try conn.inTransaction {
                let all = try Row.fetchAll(conn, sql: "SELECT id, contentHash FROM document")
                for row in all {
                    let hash: String? = row["contentHash"]
                    if hash == nil || !hashes.contains(hash!) {
                        try conn.execute(sql: "DELETE FROM document WHERE id = ?", arguments: [row["id"] as DatabaseValue])
                    }
                }
                try conn.execute(sql: """
                    DELETE FROM edition WHERE id NOT IN
                        (SELECT DISTINCT editionId FROM document WHERE editionId IS NOT NULL)
                    """)
                try conn.execute(sql: "DELETE FROM work WHERE id NOT IN (SELECT DISTINCT workId FROM edition)")
                if try conn.tableExists("conversation") {
                    try conn.execute(sql: "DELETE FROM conversation")
                }
                return .commit
            }
            try conn.execute(sql: "VACUUM")
        }
    }
}
