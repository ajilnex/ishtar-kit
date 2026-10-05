#if canImport(CryptoKit)
import CryptoKit
#else
/// Sous Linux (outil du serveur, WP-34) : l'empreinte portable, même usage.
private typealias SHA256 = PortableSHA256
#endif
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
    /// Vrai si le scan a pu s'effectuer intégralement et de manière fiable.
    public var isComplete: Bool = true
    /// Vrai si une erreur d'accès ou d'énumération a été rencontrée.
    public var hasScanErrors: Bool = false
    public var errorMessage: String? = nil

    public init(
        files: [ScannedFile] = [],
        unsupportedCount: Int = 0,
        duplicateGroups: [[ScannedFile]] = [],
        isComplete: Bool = true,
        hasScanErrors: Bool = false,
        errorMessage: String? = nil
    ) {
        self.files = files
        self.unsupportedCount = unsupportedCount
        self.duplicateGroups = duplicateGroups
        self.isComplete = isComplete
        self.hasScanErrors = hasScanErrors
        self.errorMessage = errorMessage
    }
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

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue,
              fileManager.isReadableFile(atPath: directory.path)
        else {
            report.isComplete = false
            report.hasScanErrors = true
            report.errorMessage = "Dossier source introuvable ou inaccessible : \(directory.path)"
            return report
        }

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                report.hasScanErrors = true
                report.isComplete = false
                report.errorMessage = "Erreur d'accès pendant le scan de \(url.path) : \(error.localizedDescription)"
                return true
            }
        ) else {
            report.isComplete = false
            report.hasScanErrors = true
            report.errorMessage = "Impossible d'énumérer le dossier : \(directory.path)"
            return report
        }

        let rootPath = directory.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            let resources: URLResourceValues
            do {
                resources = try fileURL.resourceValues(forKeys: Set(keys))
            } catch {
                report.hasScanErrors = true
                report.isComplete = false
                if report.errorMessage == nil {
                    report.errorMessage = "Erreur de lecture des attributs pour \(fileURL.path) : \(error.localizedDescription)"
                }
                continue
            }

            // Dossiers annexes Kindle « *.sdr » : entièrement ignorés (ni documents,
            // ni non-gérés) — on n'énumère pas leur contenu.
            if resources.isDirectory == true {
                if fileURL.pathExtension.lowercased() == "sdr" {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard resources.isRegularFile == true else { continue }

            // Le nom d'abord, le contenu ensuite : une bibliothèque réelle est
            // pleine de fichiers mal nommés (EPUB en « .pdf », RTF en « .doc »,
            // extension absente). Le reniflage ne coûte qu'une lecture d'en-tête.
            guard let format = FormatDetector.resolve(fileURL: fileURL) else {
                report.unsupportedCount += 1
                continue
            }

            let standardized = fileURL.standardizedFileURL
            let folderPath = standardized.deletingLastPathComponent().path
            let relativeFolder = folderPath.hasPrefix(rootPath)
                ? String(folderPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : ""

            let contentHash: String?
            if computeHashes {
                if let hash = Self.sha256(of: standardized) {
                    contentHash = hash
                } else {
                    // Échec de lecture du fichier pour calcul d'empreinte :
                    // Ne jamais masquer un fichier non lisible ni produire une empreinte partielle.
                    report.hasScanErrors = true
                    report.isComplete = false
                    if report.errorMessage == nil {
                        report.errorMessage = "Échec de lecture pour calcul SHA-256 : \(standardized.path)"
                    }
                    contentHash = nil
                }
            } else {
                contentHash = nil
            }

            report.files.append(ScannedFile(
                path: standardized.path,
                fileName: standardized.lastPathComponent,
                relativeFolder: relativeFolder,
                format: format,
                fileSize: Int64(resources.fileSize ?? 0),
                contentHash: contentHash
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
    /// Renvoie nil en cas d'erreur d'ouverture ou d'erreur I/O pendant la lecture (jamais d'empreinte partielle).
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var readSuccess = true
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 4 * 1024 * 1024)
            } catch {
                readSuccess = false
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        guard readSuccess else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
