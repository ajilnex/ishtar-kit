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
    public enum LibraryArchiveError: Error, Equatable, CustomStringConvertible {
        /// manifest.json ou catalog.sqlite manquant.
        case notAnArchive
        /// Le format d'archive est plus récent que ce moteur.
        case futureFormat(Int)
        /// L'archive porte des migrations que ce moteur ne connaît pas.
        case futureSchema([String])

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
    /// (écrasé s'il existe). Instantané cohérent : VACUUM INTO.
    public static func export(
        db: CatalogDatabase,
        sourceFolderPath: String?,
        to destination: URL
    ) async throws -> Manifest {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )

        let sqliteURL = destination.appendingPathComponent(catalogName)
        // VACUUM ne peut pas tourner dans une transaction.
        try await db.pool.writeWithoutTransaction { conn in
            try conn.execute(sql: "VACUUM INTO ?", arguments: [sqliteURL.path])
        }

        let documentCount = try await db.pool.read { conn in
            try Document.fetchCount(conn)
        }
        let appliedMigrations = try await db.appliedMigrationIdentifiers()

        let manifest = Manifest(
            formatVersion: Manifest.currentFormatVersion,
            appliedMigrations: appliedMigrations,
            sourceFolderPath: sourceFolderPath,
            exportDate: Date(),
            documentCount: documentCount
        )

        let data = try encoder().encode(manifest)
        try data.write(to: destination.appendingPathComponent(manifestName))
        return manifest
    }

    /// Vérifie le manifeste puis restaure le catalogue à `catalogURL`
    /// (remplacé, ainsi que ses fichiers -wal/-shm). Refuse les versions
    /// futures (format ou migrations inconnues). Si `newSourceRoot` est
    /// fourni et que l'archive connaît son ancien dossier source, les
    /// chemins des documents et le dossier source sont rebasés.
    @discardableResult
    public static func importArchive(
        from archive: URL,
        toCatalogAt catalogURL: URL,
        rebasingSourceTo newSourceRoot: String?
    ) async throws -> Manifest {
        let manifestURL = archive.appendingPathComponent(manifestName)
        let sqliteURL = archive.appendingPathComponent(catalogName)

        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: sqliteURL.path)
        else { throw LibraryArchiveError.notAnArchive }

        let manifest = try decoder().decode(
            Manifest.self, from: Data(contentsOf: manifestURL)
        )

        guard manifest.formatVersion <= Manifest.currentFormatVersion else {
            throw LibraryArchiveError.futureFormat(manifest.formatVersion)
        }

        let unknown = Set(manifest.appliedMigrations)
            .subtracting(CatalogDatabase.knownMigrationIdentifiers)
        guard unknown.isEmpty else {
            throw LibraryArchiveError.futureSchema(unknown.sorted())
        }

        // On remplace le catalogue cible et ses annexes WAL/SHM.
        try? FileManager.default.removeItem(at: catalogURL)
        try? FileManager.default.removeItem(atPath: catalogURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: catalogURL.path + "-shm")
        try FileManager.default.createDirectory(
            at: catalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sqliteURL, to: catalogURL)

        // Rejoue les migrations additives manquantes si l'archive est plus ancienne.
        let db = try CatalogDatabase(at: catalogURL)

        if let newRoot = newSourceRoot,
           let oldRoot = manifest.sourceFolderPath,
           oldRoot != newRoot {
            try await db.pool.write { conn in
                try conn.execute(sql: """
                    UPDATE document SET filePath = ? || substr(filePath, length(?) + 1)
                        WHERE filePath = ? OR filePath LIKE ? || '/%'
                    """, arguments: [newRoot, oldRoot, oldRoot, oldRoot])
                try conn.execute(sql: """
                    UPDATE source_folder SET path = ? WHERE path = ?
                    """, arguments: [newRoot, oldRoot])
            }
        }

        return manifest
    }
}
