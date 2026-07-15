import CryptoKit
import Foundation
import IshtarCatalog

/// Un fichier rencontré pendant le scan. Pur constat, aucune interprétation.
public struct ScannedFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let fileName: String
    /// Chemin du dossier contenant, relatif à la racine scannée ("" à la racine).
    public let relativeFolder: String
    public let format: DocumentFormat
    public let fileSize: Int64
    public let contentHash: String?
}

public struct ScanReport: Sendable {
    public var files: [ScannedFile] = []
    public var unsupportedCount: Int = 0
    /// Groupes de fichiers au contenu strictement identique (même SHA-256).
    public var duplicateGroups: [[ScannedFile]] = []
}

/// Scanner de dossier source.
///
/// Invariant n° 1 : le scan est local, déterministe, sans réseau et sans IA.
/// Invariant n° 2 : lecture seule — rien n'est écrit dans le dossier scanné.
public struct LibraryScanner: Sendable {
    public var computeHashes: Bool

    public init(computeHashes: Bool = true) {
        self.computeHashes = computeHashes
    }

    public func scan(directory: URL) -> ScanReport {
        var report = ScanReport()
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return report }

        let rootPath = directory.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            guard let resources = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }

            // Dossiers annexes Kindle « *.sdr » : entièrement ignorés (ni documents,
            // ni non-gérés) — on n'énumère pas leur contenu.
            if resources.isDirectory == true {
                if fileURL.pathExtension.lowercased() == "sdr" {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard resources.isRegularFile == true else { continue }

            guard let format = DocumentFormat(fileExtension: fileURL.pathExtension) else {
                report.unsupportedCount += 1
                continue
            }

            let standardized = fileURL.standardizedFileURL
            let folderPath = standardized.deletingLastPathComponent().path
            let relativeFolder = folderPath.hasPrefix(rootPath)
                ? String(folderPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : ""

            report.files.append(ScannedFile(
                path: standardized.path,
                fileName: standardized.lastPathComponent,
                relativeFolder: relativeFolder,
                format: format,
                fileSize: Int64(resources.fileSize ?? 0),
                contentHash: computeHashes ? Self.sha256(of: standardized) : nil
            ))
        }

        report.files.sort { $0.path < $1.path }
        report.duplicateGroups = Dictionary(grouping: report.files.filter { $0.contentHash != nil },
                                            by: { $0.contentHash! })
            .values
            .filter { $0.count > 1 }
            .sorted { $0[0].path < $1[0].path }

        return report
    }

    /// SHA-256 en lecture par blocs — les bibliothèques réelles contiennent des PDF de plusieurs Go.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
