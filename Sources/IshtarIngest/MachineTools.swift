#if os(Linux)
import Foundation

/// Les outils de la machine (poppler, ImageMagick) qui tiennent, sous Linux, le
/// rôle de PDFKit, Core Graphics et QuickLook sur macOS (WP-34).
///
/// Précision de l'invariant n° 5, propre à Linux : l'outil `ishtar` du serveur
/// appelle ces programmes le temps d'une lecture (texte, métadonnées, image
/// d'une page). L'application macOS n'en appelle aucun. Jamais de réseau, et
/// une limite de temps : un fichier piégé ne bloque pas l'atelier. Les images
/// de tiers ne passent que par `runImageMagick` (politique stricte).
enum MachineTools {
    /// Lance `outil` (cherché dans le PATH) et rend sa sortie standard, ou nil
    /// s'il échoue, n'existe pas ou dépasse `timeout` secondes.
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120,
                    environment: [String: String] = [:]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, nouveau in nouveau }
        }
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

    // MARK: - ImageMagick : une politique stricte

    /// Le format d'une image d'après sa signature (jamais son nom), parmi les
    /// seuls que ImageMagick reçoit : JPEG, PNG, GIF, WebP. Le reste n'est pas
    /// une couverture. Le format est ensuite imposé à `convert` par un préfixe
    /// (`png:`), pour qu'il ne devine rien d'autre (MVG, MSL, SVG, HTML…).
    static func imageCoder(for data: Data) -> String? {
        let octets = [UInt8](data.prefix(12))
        if octets.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if octets.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if octets.starts(with: Array("GIF87a".utf8)) || octets.starts(with: Array("GIF89a".utf8)) { return "gif" }
        if octets.count == 12, octets.starts(with: Array("RIFF".utf8)), Array(octets[8...]) == Array("WEBP".utf8) { return "webp" }
        return nil
    }

    /// La politique d'ImageMagick pour des images de tiers : tout est interdit
    /// sauf la lecture des quatre formats ci-dessus (et l'écriture du PNG de
    /// sortie) ; aucun délégué (programme externe, URL), aucun filtre, aucun
    /// `@fichier` (liste de fichiers à lire) ; des limites de mémoire, de
    /// dimensions et de temps contre les images-bombes.
    static let imageMagickPolicy = """
    <policymap>
      <policy domain="resource" name="memory" value="256MiB"/>
      <policy domain="resource" name="map" value="512MiB"/>
      <policy domain="resource" name="disk" value="1GiB"/>
      <policy domain="resource" name="area" value="64MP"/>
      <policy domain="resource" name="width" value="16KP"/>
      <policy domain="resource" name="height" value="16KP"/>
      <policy domain="resource" name="time" value="60"/>
      <policy domain="delegate" rights="none" pattern="*"/>
      <policy domain="coder" rights="none" pattern="*"/>
      <policy domain="coder" rights="read" pattern="GIF"/>
      <policy domain="coder" rights="read" pattern="JPEG"/>
      <policy domain="coder" rights="read | write" pattern="PNG"/>
      <policy domain="coder" rights="read" pattern="WEBP"/>
      <policy domain="filter" rights="none" pattern="*"/>
      <policy domain="path" rights="none" pattern="@*"/>
      <policy domain="module" rights="none" pattern="*"/>
      <policy domain="module" rights="read | write" pattern="GIF"/>
      <policy domain="module" rights="read | write" pattern="JPEG"/>
      <policy domain="module" rights="read | write" pattern="PNG"/>
      <policy domain="module" rights="read | write" pattern="WEBP"/>
    </policymap>
    """

    /// Lance `convert` sous cette politique, ou rend nil : sans politique posée, il
    /// ne part pas. ImageMagick 6 charge tous les `policy.xml` qu'il trouve
    /// (`MAGICK_CONFIGURE_PATH` d'abord, puis le système) et, pour les droits, la
    /// dernière règle qui correspond l'emporte : une règle permissive d'un fichier
    /// lu après le nôtre l'emporterait. Les fichiers propres à l'utilisateur sont
    /// donc écartés (`HOME` et `XDG_CONFIG_HOME` vers le dossier jetable) et les
    /// tests vérifient, sur la machine, que ce qui doit être refusé l'est.
    static func runImageMagick(_ arguments: [String], timeout: TimeInterval = 120) -> Data? {
        withTemporaryDirectory { dir -> Data? in
            let config = dir.appendingPathComponent("magick", isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)) != nil,
                  (try? Data(imageMagickPolicy.utf8).write(to: config.appendingPathComponent("policy.xml"))) != nil
            else { return nil }
            return run("convert", arguments, timeout: timeout, environment: [
                "MAGICK_CONFIGURE_PATH": config.path, "HOME": dir.path, "XDG_CONFIG_HOME": dir.path,
            ])
        }
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
