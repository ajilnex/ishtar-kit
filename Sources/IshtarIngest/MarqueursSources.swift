import Foundation

/// Marqueurs propres aux sites de provenance des fichiers, lus dans un fichier
/// local hors dépôt : `$ISHTAR_MARQUEURS`, sinon `~/.config/ishtar/marqueurs-sources.txt`.
///
/// Format : un marqueur par ligne, `section: valeur` ; `#` ouvre un commentaire.
/// - `parenthese:` contenu exact (casse ignorée) d'une parenthèse finale de nom de fichier ;
/// - `rebut:` fragment qui disqualifie un sous-titre embarqué.
/// Sans fichier, aucun marqueur n'est reconnu et le reste fonctionne normalement.
public struct MarqueursSources: Sendable, Equatable {
    public var parentheses: Set<String>
    public var rebuts: [String]

    public init(parentheses: Set<String> = [], rebuts: [String] = []) {
        self.parentheses = Set(parentheses.map { $0.lowercased() })
        self.rebuts = rebuts.map { $0.lowercased() }
    }

    public static let vide = MarqueursSources()

    /// Analyse le contenu d'un fichier de marqueurs. Pur.
    public static func parse(_ texte: String) -> MarqueursSources {
        var parentheses: Set<String> = [], rebuts: [String] = []
        for ligne in texte.split(whereSeparator: \.isNewline) {
            var contenu = Substring(ligne)
            if let diese = contenu.firstIndex(of: "#") { contenu = contenu[..<diese] }
            guard let deuxPoints = contenu.firstIndex(of: ":") else { continue }
            let section = contenu[..<deuxPoints].trimmingCharacters(in: .whitespaces).lowercased()
            let valeur = contenu[contenu.index(after: deuxPoints)...].trimmingCharacters(in: .whitespaces)
            guard !valeur.isEmpty else { continue }
            switch section {
            case "parenthese": parentheses.insert(valeur)
            case "rebut": rebuts.append(valeur)
            default: break
            }
        }
        return MarqueursSources(parentheses: parentheses, rebuts: rebuts)
    }

    /// Chemin du fichier local : variable d'environnement, sinon l'emplacement par défaut.
    public static func cheminParDefaut() -> String {
        if let chemin = ProcessInfo.processInfo.environment["ISHTAR_MARQUEURS"], !chemin.isEmpty {
            return (chemin as NSString).expandingTildeInPath
        }
        return ("~/.config/ishtar/marqueurs-sources.txt" as NSString).expandingTildeInPath
    }

    /// Charge le fichier ; vide s'il manque ou est illisible.
    public static func charger(chemin: String = cheminParDefaut()) -> MarqueursSources {
        guard let texte = try? String(contentsOfFile: chemin, encoding: .utf8) else { return .vide }
        return parse(texte)
    }

    /// Marqueurs courants, chargés une fois (paresseusement). Les tests peuvent les remplacer.
    public static var courants: MarqueursSources {
        get { stockage.lire() }
        set { stockage.ecrire(newValue) }
    }

    private static let stockage = Stockage(charger())

    /// Valeur partagée protégée par un verrou (lectures et écritures concurrentes sûres).
    private final class Stockage: @unchecked Sendable {
        private let verrou = NSLock()
        private var valeur: MarqueursSources
        init(_ valeur: MarqueursSources) { self.valeur = valeur }
        func lire() -> MarqueursSources { verrou.lock(); defer { verrou.unlock() }; return valeur }
        func ecrire(_ nouvelle: MarqueursSources) { verrou.lock(); defer { verrou.unlock() }; valeur = nouvelle }
    }
}
