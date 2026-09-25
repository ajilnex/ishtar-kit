import Foundation
import GRDB

/// Le nom qu'un fichier porte sur le disque en mode « bibliothèque confiée »
/// (décision d'Aubin du 24/09 : l'étiquette des téléchargements de Rayons,
/// généralisée) : `Adorno — Minima moralia (1951).pdf`.
///
/// Un dossier est un rayon : on y classe, donc le nom de famille d'abord
/// (NORMES §6), seul, comme au dos d'un livre ; deux auteurs « Deleuze &
/// Guattari », trois et plus « Hogrebe et al. ». Le titre est celui de
/// l'édition (une traduction garde le sien) ; l'année, celle de l'œuvre —
/// « 350 av. J.-C. » pour l'Antiquité. Aucun caractère que refusent exFAT
/// ou Windows ; Unicode composé (NFC).
public enum FileLabel {
    /// Caractères interdits sur exFAT / Windows, et contrôles.
    static let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)

    public static func family(ofName name: String, sortName: String?) -> String {
        if let sortName, let family = sortName.components(separatedBy: ",").first, !family.isEmpty {
            return family.trimmingCharacters(in: .whitespaces)
        }
        // Une particule en capitale fait partie du nom (« André De Tienne »,
        // « Ursula K. Le Guin ») ; en minuscule, non (« Michel de Montaigne »).
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = words.last else { return name }
        if words.count >= 3, ["De", "Van", "Le", "La", "Du", "Di", "Da", "Del", "Des", "Von", "Ten", "Ter"].contains(words[words.count - 2]) {
            return words[words.count - 2] + " " + last
        }
        return last
    }

    static func authorPart(_ families: [String]) -> String {
        switch families.count {
        case 0: return "Anonyme"
        case 1: return families[0]
        case 2: return "\(families[0]) & \(families[1])"
        default: return "\(families[0]) et al."
        }
    }

    static func yearPart(_ year: String?) -> String? {
        guard let year = year?.trimmingCharacters(in: .whitespaces), !year.isEmpty,
              !["nd", "sd", "s.d."].contains(year.lowercased()) else { return nil }
        if year.hasPrefix("-"), year.dropFirst().allSatisfy(\.isNumber) { return "\(year.dropFirst()) av. J.-C." }
        return year
    }

    /// Le titre rendu sûr pour un nom de fichier : « : » devient « – », les
    /// autres interdits disparaissent, 120 caractères au plus, coupés à un mot.
    static func safeTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: #"\s*:\s*"#, with: " – ", options: .regularExpression)
        t = String(t.unicodeScalars.filter { !forbidden.contains($0) }.map(Character.init))
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .–-"))
        if t.count > 120 {
            let cut = t.prefix(120)
            t = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)])
        }
        return t
    }

    /// Le nom complet, extension comprise (pur).
    public static func name(families: [String], title: String, year: String?, editionYear: String? = nil,
                            ext: String, copy: Int = 1) -> String {
        var base = "\(authorPart(families)) — \(safeTitle(title))"
        let y = yearPart(year)
        if let y, let e = yearPart(editionYear), e != y { base += " (\(y), éd. \(e))" }
        else if let y { base += " (\(y))" }
        if copy > 1 { base += " [\(copy)]" }
        base = String(base.unicodeScalars.filter { !forbidden.contains($0) }.map(Character.init))
        return (base + "." + ext.lowercased()).precomposedStringWithCanonicalMapping
    }
}

/// Un renommage prévu.
public struct Renaming: Sendable, Equatable {
    public let documentId: UUID
    public let from: String
    public let to: String
    /// La fiche a été vérifiée (confiance haute) : son nom l'emporte sur
    /// l'ancien nom de fichier.
    public let verified: Bool

    public init(documentId: UUID, from: String, to: String, verified: Bool = false) {
        self.documentId = documentId
        self.from = from
        self.to = to
        self.verified = verified
    }
}

extension CatalogStore {
    /// Les renommages que demande l'étiquette, pour les documents sous
    /// `root`, hors `excludedFolders`. Seules les fiches sûres sont rangées :
    /// un auteur, un titre, et une confiance qui n'est pas « faible ».
    public func arrangement(root: String, excludedFolders: Set<String>) async throws -> [Renaming] {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        return try await db.pool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT d.id AS id, d.filePath AS path, d.format AS format, e.id AS editionId,
                       COALESCE(NULLIF(e.title, ''), w.title) AS title, w.date AS workDate, e.year AS editionYear,
                       w.confidence AS confidence
                FROM document d JOIN edition e ON e.id = d.editionId JOIN work w ON w.id = e.workId
                WHERE d.isMissing = 0 ORDER BY d.filePath
                """)
            var authors: [UUID: [String]] = [:]
            for row in try Row.fetchAll(conn, sql: """
                SELECT e.id AS editionId, c.name AS name, c.sortName AS sortName
                FROM edition e JOIN work_creator wc ON wc.workId = e.workId AND wc.role = 'author'
                JOIN creator c ON c.id = wc.creatorId ORDER BY wc.position
                """) {
                authors[row["editionId"], default: []].append(FileLabel.family(ofName: row["name"], sortName: row["sortName"]))
            }
            // Deux éditions d'une même œuvre au même format, deux fichiers d'une même édition :
            // l'année d'édition, puis [2], [3] départagent.
            var taken: [String: Set<String>] = [:]   // dossier → noms (minuscules)
            for row in rows { taken[(row["path"] as String as NSString).deletingLastPathComponent, default: []]
                .insert(((row["path"] as String) as NSString).lastPathComponent.lowercased()) }
            var plan: [Renaming] = []
            for row in rows {
                let path: String = row["path"]
                guard path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                if relative.split(separator: "/").dropLast().contains(where: { excludedFolders.contains(String($0)) }) { continue }
                let families = authors[row["editionId"]] ?? []
                let title: String = row["title"]
                guard !families.isEmpty, !title.isEmpty, (row["confidence"] as String) != "low" else { continue }
                let dir = (path as NSString).deletingLastPathComponent
                let current = (path as NSString).lastPathComponent
                let ext = (current as NSString).pathExtension
                let workYear: String? = row["workDate"] ?? row["editionYear"]
                let editionYear: String? = row["workDate"] != nil ? row["editionYear"] : nil
                var copy = 1
                var target = FileLabel.name(families: families, title: title, year: workYear, editionYear: editionYear, ext: ext)
                guard target != current.precomposedStringWithCanonicalMapping else { continue }
                // Son propre nom n'est pas « pris » : sinon « X [2] » fuirait vers « X [3] ».
                taken[dir, default: []].remove(current.lowercased())
                while taken[dir, default: []].contains(target.lowercased()) {
                    copy += 1
                    target = FileLabel.name(families: families, title: title, year: workYear, editionYear: editionYear, ext: ext, copy: copy)
                }
                // Le numéro de copie retombe sur le nom actuel : rien à faire.
                if target == current.precomposedStringWithCanonicalMapping {
                    taken[dir, default: []].insert(current.lowercased()); continue
                }
                taken[dir, default: []].insert(target.lowercased())
                plan.append(Renaming(documentId: row["id"], from: path, to: (dir as NSString).appendingPathComponent(target),
                                     verified: (row["confidence"] as String) == "high"))
            }
            return plan
        }
    }

    /// Exécute un renommage : le fichier d'abord, puis la fiche ; si la fiche
    /// ne peut être écrite, le fichier reprend son nom. Rend faux si le
    /// fichier source manque ou si la cible existe déjà.
    public func perform(_ r: Renaming) async throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: r.from), !fm.fileExists(atPath: r.to) else { return false }
        try fm.moveItem(atPath: r.from, toPath: r.to)
        do {
            try await db.pool.write { conn in
                try conn.execute(sql: "UPDATE document SET filePath = ? WHERE id = ?", arguments: [r.to, r.documentId])
            }
        } catch {
            try? fm.moveItem(atPath: r.to, toPath: r.from)
            throw error
        }
        return true
    }

    /// Le chemin d'un document.
    public func path(ofDocument id: UUID) async throws -> String? {
        try await db.pool.read { try String.fetchOne($0, sql: "SELECT filePath FROM document WHERE id = ?", arguments: [id]) }
    }
}
