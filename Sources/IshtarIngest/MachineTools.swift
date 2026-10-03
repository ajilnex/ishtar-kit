#if os(Linux)
import Foundation

/// Les outils de la machine (poppler, ImageMagick) qui tiennent, sous Linux, le
/// rôle de PDFKit, Core Graphics et QuickLook sur macOS (WP-34).
///
/// Précision de l'invariant n° 5, propre à Linux : l'outil `ishtar` du serveur
/// appelle ces programmes le temps d'une lecture (texte, métadonnées, image
/// d'une page). L'application macOS n'en appelle aucun. Jamais de réseau, et
/// une limite de temps : un fichier piégé ne bloque pas l'atelier.
enum MachineTools {
    /// Lance `outil` (cherché dans le PATH) et rend sa sortie standard, ou nil
    /// s'il échoue, n'existe pas ou dépasse `timeout` secondes.
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Lire jusqu'au bout AVANT d'attendre : un tuyau plein bloquerait l'outil.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return data
    }

    /// Un dossier de travail jetable, effacé après usage.
    static func withTemporaryDirectory<T>(_ body: (URL) -> T) -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ishtar-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return body(dir)
    }
}
#endif
