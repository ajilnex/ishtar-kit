import Foundation
import GRDB

/// Export/import d'une bibliothèque en un seul objet Finder :
/// un dossier-bundle `.ishtar-archive` = catalog.sqlite (instantané VACUUM
/// INTO, sans WAL) + manifest.json versionné. Les fichiers du dossier
/// source ne sont JAMAIS inclus ni touchés : le catalogue seulement.
public enum LibraryArchive {
    /// Le manifeste versionné écrit au côté de catalog.sqlite.
    public struct Manifest: Codable, Sendable {
        public var formatVersion: Int
        public var appliedMigrations: [String]
        public var sourceFolderPath: String?
        public var exportDate: Date
        public var documentCount: Int

        public static let currentFormatVersion = 1

        public init(
            formatVersion: Int,
            appliedMigrations: [String],
            sourceFolderPath: String?,
            exportDate: Date,
            documentCount: Int
        ) {
            self.formatVersion = formatVersion
            self.appliedMigrations = appliedMigrations
            self.sourceFolderPath = sourceFolderPath
            self.exportDate = exportDate
            self.documentCount = documentCount
        }
    }

    /// Les refus francs de l'import.
    public enum LibraryArchiveError: Error, Equatable, CustomStringConvertible, LocalizedError {
        /// manifest.json ou catalog.sqlite manquant.
        case notAnArchive
        /// Le format d'archive est plus récent que ce moteur.
        case futureFormat(Int)
        /// L'archive porte des migrations que ce moteur ne connaît pas.
        case futureSchema([String])
        case invalidCatalog(String)
        case destinationExists

        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case .notAnArchive:
                return "Ce dossier n'est pas une archive Ishtar valide "
                    + "(manifest.json ou catalog.sqlite manquant)."
            case let .futureFormat(version):
                return "Cette archive vient d'une version d'Ishtar plus récente "
                    + "(format \(version), maximum pris en charge "
                    + "\(Manifest.currentFormatVersion))."
            case let .futureSchema(unknown):
                return "Cette archive vient d'une version d'Ishtar plus récente "
                    + "(migrations inconnues : \(unknown.joined(separator: ", ")))."
            case let .invalidCatalog(reason):
                return "Archive refusée : \(reason). Le catalogue courant est conservé."
            case .destinationExists:
                return "Une archive existe déjà à cet emplacement. Choisissez un nouveau nom."
            }
        }
    }

    private static let manifestName = "manifest.json"
    private static let catalogName = "catalog.sqlite"

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Exporte le catalogue. `destination` est le dossier-bundle à créer
    /// sans écraser une archive existante. Le manifeste est lu dans le même
    /// instantané que le catalogue. Le dossier n'apparaît qu'une fois complet.
    public static func export(
        db: CatalogDatabase,
        sourceFolderPath: String?,
        to destination: URL
    ) async throws -> Manifest {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw LibraryArchiveError.destinationExists
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".ishtar-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let sqliteURL = staging.appendingPathComponent(catalogName)
        // VACUUM ne peut pas tourner dans une transaction.
        try await db.pool.writeWithoutTransaction { conn in
            try conn.execute(sql: "VACUUM INTO ?", arguments: [sqliteURL.path])
        }

        var config = Configuration()
        config.readonly = true
        let snapshot = try DatabaseQueue(path: sqliteURL.path, configuration: config)
        let (documentCount, appliedMigrations) = try await snapshot.read { conn in
            let applied = try CatalogDatabase.migrator.appliedIdentifiers(conn)
            return (try Document.fetchCount(conn),
                    CatalogDatabase.knownMigrationIdentifiers.filter(applied.contains))
        }

        let manifest = Manifest(
            formatVersion: Manifest.currentFormatVersion,
            appliedMigrations: appliedMigrations,
            sourceFolderPath: sourceFolderPath,
            exportDate: Date(),
            documentCount: documentCount
        )

        let data = try encoder().encode(manifest)
        try data.write(to: staging.appendingPathComponent(manifestName), options: .atomic)
        try fm.moveItem(at: staging, to: destination)
        return manifest
    }

    /// Valide et migre une copie temporaire AVANT d'ouvrir la destination.
    /// Pour un catalogue déjà ouvert, utiliser `restore(from:into:...)` avec
    /// son pool existant ; ne jamais remplacer son fichier sous ses connexions.
    @discardableResult
    public static func importArchive(
        from archive: URL,
        toCatalogAt catalogURL: URL,
        rebasingSourceTo newSourceRoot: String?
    ) async throws -> Manifest {
        let prepared = try await prepare(archive: archive, newSourceRoot: newSourceRoot)
        defer { try? FileManager.default.removeItem(at: prepared.folder) }
        let destination = try CatalogDatabase(at: catalogURL)
        try await copy(prepared.db, into: destination)
        return prepared.manifest
    }

    /// Le demandeur arrête et attend ses tâches d'écriture avant cet appel.
    /// SQLite remplace le contenu dans une transaction de backup ; en cas
    /// d'erreur son rollback conserve la destination, WAL compris.
    @discardableResult
    public static func restore(from archive: URL, into destination: CatalogDatabase,
                               rebasingSourceTo newSourceRoot: String?) async throws -> Manifest {
        let prepared = try await prepare(archive: archive, newSourceRoot: newSourceRoot)
        defer { try? FileManager.default.removeItem(at: prepared.folder) }
        try await copy(prepared.db, into: destination)
        return prepared.manifest
    }

    private static func copy(_ source: CatalogDatabase, into destination: CatalogDatabase) async throws {
        try Task.checkCancellation()
        try await Task.detached {
            try source.pool.backup(to: destination.pool)
            destination.pool.invalidateReadOnlyConnections()
        }.value
    }

    private static func prepare(archive: URL, newSourceRoot: String?) async throws
        -> (folder: URL, db: CatalogDatabase, manifest: Manifest) {
        let fm = FileManager.default
        let manifestURL = archive.appendingPathComponent(manifestName)
        let sourceURL = archive.appendingPathComponent(catalogName)
        for url in [manifestURL, sourceURL] {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LibraryArchiveError.notAnArchive
            }
        }
        let manifest = try decoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion <= Manifest.currentFormatVersion else {
            throw LibraryArchiveError.futureFormat(manifest.formatVersion)
        }
        guard manifest.formatVersion == 1 else {
            throw LibraryArchiveError.invalidCatalog("format non pris en charge")
        }
        let unknown = Set(manifest.appliedMigrations).subtracting(CatalogDatabase.knownMigrationIdentifiers)
        guard unknown.isEmpty else { throw LibraryArchiveError.futureSchema(unknown.sorted()) }
        let folder = fm.temporaryDirectory.appendingPathComponent("ishtar-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let stagedURL = folder.appendingPathComponent(catalogName)
            try fm.copyItem(at: sourceURL, to: stagedURL)
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: stagedURL.path, configuration: config)
            try await queue.read { conn in
                guard try String.fetchAll(conn, sql: "PRAGMA quick_check") == ["ok"],
                      try Row.fetchAll(conn, sql: "PRAGMA foreign_key_check").isEmpty else {
                    throw LibraryArchiveError.invalidCatalog("intégrité SQLite invalide")
                }
                let applied = try String.fetchAll(conn, sql: "SELECT identifier FROM grdb_migrations")
                guard Set(applied) == Set(manifest.appliedMigrations),
                      applied.count == manifest.appliedMigrations.count,
                      try Document.fetchCount(conn) == manifest.documentCount else {
                    throw LibraryArchiveError.invalidCatalog("le manifeste ne correspond pas au catalogue")
                }
            }
            let staged = try CatalogDatabase(at: stagedURL)
            if let newRoot = newSourceRoot, let oldRoot = manifest.sourceFolderPath,
               URL(fileURLWithPath: oldRoot).standardizedFileURL.path != URL(fileURLWithPath: newRoot).standardizedFileURL.path {
                try await CatalogStore(db: staged).relocateLibrary(from: oldRoot, to: newRoot)
            }
            return (folder, staged, manifest)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}
