import Foundation

/// L'atelier d'un fonds confié (WP-34). Le donateur envoie une copie de ses
/// livres, que Rayons range dans `<fonds>/recu/` : personne n'y touche plus
/// (invariant n° 2). L'atelier en tire ses copies de travail, `fichiers/`, que
/// le catalogue du fonds nomme selon les normes et d'où elles sont publiées.
/// Une copie par empreinte (les doublons exacts du fonds n'en font qu'une, la
/// mieux nommée),
/// jamais de livre verrouillé par un éditeur (DRM) ; les fiches Calibre
/// (`metadata.opf`, `cover.*`) suivent leur dossier.
public enum FondsAtelier {
    public enum AtelierError: Error, CustomStringConvertible {
        case scan(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .scan(let message): "Dépôt illisible : \(message)"
            case .unreadable(let path): "Livre illisible dans le dépôt : \(path)"
            }
        }
    }

    /// Ce que l'atelier lit du registre de Rayons (`depot.json`).
    public struct Depot: Decodable, Sendable, Equatable {
        public let id: String
        public let nom: String
        /// `envoi` (des livres arrivent), `recu` (l'envoi est fini), `retire`.
        public let etat: String
    }

    public static func depot(in fonds: URL) throws -> Depot {
        try JSONDecoder().decode(Depot.self, from: Data(contentsOf: fonds.appendingPathComponent("depot.json")))
    }

    /// Le bilan d'une copie.
    public struct Copie: Sendable, Equatable {
        /// Livres reconnus dans `recu/`.
        public var livres = 0
        /// Copiés à ce passage (chemins relatifs au dépôt).
        public var copies: [String] = []
        /// Déjà copiés à un passage précédent.
        public var dejaLa = 0
        /// Même contenu qu'un autre livre du dépôt : écartés.
        public var doublons: [String] = []
        /// Verrou d'éditeur (DRM) : restent dans `recu/`, ni copiés ni publiés.
        public var verrous: [String] = []
        /// Envois inachevés (`*.part`, la convention de Rayons) : attendus.
        public var incomplets: [String] = []
        /// Fiches Calibre copiées à ce passage.
        public var compagnons = 0
        public init() {}
    }

    /// Les compagnons d'une bibliothèque Calibre, que la réception accepte aussi.
    static func isCompanion(_ name: String) -> Bool {
        ["metadata.opf", "cover.jpg", "cover.jpeg", "cover.png"].contains(name.lowercased())
    }

    /// Copie dans `fichiers` les livres de `recu` qui n'y sont pas encore.
    /// `known` : les empreintes déjà au catalogue du fonds (les copies des
    /// passages précédents, renommées depuis peut-être). Même arborescence
    /// que le dépôt ; un nom déjà pris reçoit « [2] ». Chaque copie passe par
    /// un nom caché, puis prend le sien : une copie interrompue ne laisse
    /// jamais un livre tronqué. Ne modifie jamais `recu`.
    public static func copyNew(from recu: URL, to fichiers: URL, known: Set<String>) throws -> Copie {
        let fm = FileManager.default
        try fm.createDirectory(at: fichiers, withIntermediateDirectories: true)
        removeLeftovers(in: fichiers)
        let report = LibraryScanner().scan(directory: recu)
        guard report.isComplete, !report.hasScanErrors else { throw AtelierError.scan(report.errorMessage ?? recu.path) }

        var copie = Copie()
        var candidates: [(file: ScannedFile, relative: String, hash: String)] = []
        for file in report.files.sorted(by: { $0.path < $1.path }) {
            let relative = file.relativeFolder.isEmpty ? file.fileName : file.relativeFolder + "/" + file.fileName
            // Un envoi inachevé : son contenu peut passer pour un livre, tronqué.
            if file.fileName.hasSuffix(".part") { copie.incomplets.append(relative); continue }
            copie.livres += 1
            if FormatDetector.probe(fileURL: URL(fileURLWithPath: file.path)).isProtected {
                copie.verrous.append(relative)
                continue
            }
            guard let hash = file.contentHash else { throw AtelierError.unreadable(relative) }
            candidates.append((file, relative, hash))
        }
        // De plusieurs fichiers identiques, on garde le mieux nommé (une étiquette
        // « Auteur — Titre (Année) » se lit ; « brassier copie.pdf », non).
        func rank(_ name: String) -> Int { FilenameParser.parse(fileName: name).confidence == .structured ? 0 : 1 }
        let kept = Dictionary(grouping: candidates, by: \.hash).mapValues { group in
            group.min { (rank($0.file.fileName), $0.relative) < (rank($1.file.fileName), $1.relative) }!.relative
        }
        for candidate in candidates {
            guard kept[candidate.hash] == candidate.relative else { copie.doublons.append(candidate.relative); continue }
            if known.contains(candidate.hash) { copie.dejaLa += 1; continue }
            let file = candidate.file
            let folder = file.relativeFolder.isEmpty ? fichiers : fichiers.appendingPathComponent(file.relativeFolder, isDirectory: true)
            try copy(URL(fileURLWithPath: file.path), into: folder, named: file.fileName)
            copie.copies.append(candidate.relative)
        }

        // Les fiches Calibre : légères, copiées si elles manquent, à leur place.
        let base = recu.standardizedFileURL.path
        if let walker = fm.enumerator(at: recu, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where isCompanion(url.lastPathComponent) {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                let target = fichiers.appendingPathComponent(String(path.dropFirst(base.count + 1)))
                guard !fm.fileExists(atPath: target.path) else { continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: target)
                copie.compagnons += 1
            }
        }
        return copie
    }

    /// Une copie sûre : sous un nom caché d'abord, puis le nom libre le plus
    /// proche (« Titre [2].pdf » si « Titre.pdf » est pris).
    static func copy(_ source: URL, into folder: URL, named name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(name).part")
        try? fm.removeItem(at: temporary)
        try fm.copyItem(at: source, to: temporary)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(stem) [\(n)]" : "\(stem) [\(n)].\(ext)")
            n += 1
        }
        try fm.moveItem(at: temporary, to: target)
    }

    /// Les copies qu'un passage interrompu a laissées en chemin.
    static func removeLeftovers(in fichiers: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: fichiers, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "part" {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Le bilan, que Rayons montre au donateur

    /// Un livre dont l'identification est incertaine : il garde son nom
    /// d'arrivée et attend la revue.
    public struct ARevoir: Codable, Sendable, Equatable {
        public let chemin: String
        public let titre: String
        public let auteurs: String?
        public init(chemin: String, titre: String, auteurs: String?) {
            self.chemin = chemin
            self.titre = titre
            self.auteurs = auteurs
        }
    }

    public struct CleChangee: Codable, Sendable, Equatable {
        public let avant: String
        public let apres: String
        public init(avant: String, apres: String) {
            self.avant = avant
            self.apres = apres
        }
    }

    /// `catalogue/atelier.json` : le dernier passage de l'atelier.
    public struct Bilan: Codable, Sendable, Equatable {
        public var version = 1
        public var fonds: String
        public var nom: String
        public var fait: Date
        /// Livres reçus (formats gérés), puis ce qu'il en est advenu.
        public var livres: Int
        public var copies: Int
        public var doublons: [String]
        public var verrous: [String]
        public var incomplets: [String]
        /// Documents au catalogue du fonds.
        public var catalogues: Int
        public var aRevoir: [ARevoir]
        public var renommes: Int
        public var cles: [CleChangee]
        /// Éditions publiées, couvertures.
        public var publies: Int
        public var couvertures: Int

        public init(fonds: String, nom: String, fait: Date, copie: Copie, catalogues: Int, aRevoir: [ARevoir],
                    renommes: Int, cles: [CleChangee], publies: Int, couvertures: Int) {
            self.fonds = fonds
            self.nom = nom
            self.fait = fait
            self.livres = copie.livres
            self.copies = copie.copies.count
            self.doublons = copie.doublons
            self.verrous = copie.verrous
            self.incomplets = copie.incomplets
            self.catalogues = catalogues
            self.aRevoir = aRevoir
            self.renommes = renommes
            self.cles = cles
            self.publies = publies
            self.couvertures = couvertures
        }

        public func write(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }
}
