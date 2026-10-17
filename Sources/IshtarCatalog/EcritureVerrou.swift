import Foundation

/// Le verrou d'écriture du catalogue (`ecriture.verrou`, à côté de `catalog.sqlite`) :
/// qui écrit hors de l'application le pose, l'enlève une fois fini ; les relais
/// de publication le voient. Poser le verrou suppose Ishtar fermée et aucun
/// processus sur la base. À appeler **avant** d'ouvrir le catalogue (sinon on
/// se verrait soi-même ouvert).
public enum EcritureVerrou {
    public struct Refus: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Les contrôles de processus, remplaçables en test.
    public struct Controles: Sendable {
        public var ishtarOuverte: @Sendable () throws -> Bool
        public var fichiersOuverts: @Sendable (_ catalogue: URL) throws -> Bool
        public init(ishtarOuverte: @escaping @Sendable () throws -> Bool,
                    fichiersOuverts: @escaping @Sendable (URL) throws -> Bool) {
            self.ishtarOuverte = ishtarOuverte
            self.fichiersOuverts = fichiersOuverts
        }

        public static let reels = Controles(
            ishtarOuverte: {
                #if os(macOS)
                switch try sortie("/usr/bin/pgrep", ["-x", "Ishtar"]).statut {
                case 0: return true
                case 1: return false
                default: throw Refus(message: "Impossible de vérifier que Ishtar est fermée ; arrêt.")
                }
                #else
                return false
                #endif
            },
            fichiersOuverts: { catalogue in
                #if os(macOS)
                // Seuls les fichiers qui existent : lsof signale les autres sur sa sortie d'erreur (écartée).
                let fichiers = [catalogue.path, catalogue.path + "-wal", catalogue.path + "-shm"]
                    .filter { FileManager.default.fileExists(atPath: $0) }
                let r = try sortie("/usr/sbin/lsof", fichiers)
                guard r.statut <= 1 else { throw Refus(message: "Impossible de vérifier les fichiers ouverts ; arrêt.") }
                return !r.texte.isEmpty
                #else
                return false
                #endif
            })
    }

    public static func url(pour catalogue: URL) -> URL {
        catalogue.deletingLastPathComponent().appendingPathComponent("ecriture.verrou")
    }

    /// Ce qui s'oppose à écrire, ou nil. Ne pose rien.
    public static func obstacle(pour catalogue: URL, controles: Controles = .reels) -> String? {
        do {
            if FileManager.default.fileExists(atPath: url(pour: catalogue).path) {
                return "ecriture.verrou existe déjà (quelqu'un écrit, ou une écriture s'est mal terminée) ; arrêt."
            }
            if try controles.ishtarOuverte() { return "Ishtar est ouverte : la fermer puis relancer." }
            if try controles.fichiersOuverts(catalogue) { return "Un processus tient le catalogue ouvert ; arrêt." }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public struct Jeton: Sendable {
        let chemin: URL
        public func liberer() { try? FileManager.default.removeItem(at: chemin) }
    }

    /// Contrôle puis pose le verrou (création exclusive).
    public static func poser(pour catalogue: URL, qui: String, pourquoi: String,
                             controles: Controles = .reels, maintenant: Date = Date()) throws -> Jeton {
        if let raison = obstacle(pour: catalogue, controles: controles) { throw Refus(message: raison) }
        let chemin = url(pour: catalogue)
        let texte = "qui: \(qui)\ndepuis: \(ISO8601DateFormatter().string(from: maintenant))\npourquoi: \(pourquoi)\n"
        let fd = open(chemin.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Refus(message: "Impossible de poser le verrou (\(chemin.path)) ; arrêt.") }
        defer { close(fd) }
        let octets = Array(texte.utf8)
        _ = octets.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        return Jeton(chemin: chemin)
    }

    #if os(macOS)
    private static func sortie(_ exe: String, _ args: [String]) throws -> (statut: Int32, texte: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw Refus(message: "Contrôle impossible (\(exe)) ; arrêt.") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    #endif
}
