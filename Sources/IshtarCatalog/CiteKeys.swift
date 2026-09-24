import Foundation
import GRDB

/// La clé de citation d'une édition : ce qu'un billet écrit pour la citer
/// (`Adorno1951Minima`). Elle a trois états :
///
/// - `generated` — **provisoire** : calculée depuis la fiche, elle suit ses
///   corrections tant que personne ne la cite ;
/// - `stable` — figée au moment où elle sort vers un outil de citation
///   (Zotero, BibTeX) : dès lors, **elle ne change plus d'elle-même** ;
/// - `manual` — saisie par l'utilisateur, jamais touchée par une machine.
public struct EditionKey: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "edition_key"

    public enum Origin: String, Codable, Sendable, DatabaseValueConvertible {
        /// Calculée par `CiteKeyGenerator`, provisoire.
        case generated
        /// Figée : elle a été exportée, quelqu'un peut la citer.
        case stable
        /// Saisie ou corrigée par l'utilisateur.
        case manual
    }

    public var editionId: UUID
    public var key: String
    public var origin: Origin
    public var dateAssigned: Date

    public init(editionId: UUID, key: String, origin: Origin, dateAssigned: Date = Date()) {
        self.editionId = editionId
        self.key = key
        self.origin = origin
        self.dateAssigned = dateAssigned
    }
}

/// Fabrique des clés. Fonctions PURES.
///
/// Forme : nom de famille du premier auteur + année + premier mot significatif
/// du titre, en ASCII, chaque partie capitalisée : `Adorno1951Minima`.
/// L'année est celle de l'œuvre (convention des noms de fichiers
/// `Auteur_Année_Titre`) ; en cas de collision, l'année de l'édition départage
/// (`Adorno1951Minima-2003`), sinon une lettre (`-b`, `-c`…).
public enum CiteKeyGenerator {
    /// Articles, prépositions et conjonctions à sauter en tête de titre.
    static let stopwords: Set<String> = [
        // français
        "le", "la", "les", "l", "un", "une", "des", "du", "de", "d", "et", "en",
        "au", "aux", "a", "sur", "pour", "par", "dans",
        // anglais
        "the", "an", "of", "and", "on", "in", "to", "for", "from",
        // allemand
        "der", "die", "das", "des", "dem", "den", "ein", "eine", "einer", "und",
        "zur", "zum", "vom", "uber",
        // latin, italien, espagnol
        "de", "il", "lo", "gli", "el", "los", "las", "del", "y", "e",
    ]

    /// Translittération ASCII : « Gödel » → « Godel », « Straße » → « Strasse »,
    /// « Πλάτων » → « Platon ».
    static func ascii(_ value: String) -> String {
        let latin = value.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false)
            ?? value.folding(options: .diacriticInsensitive, locale: nil)
        return String(latin.unicodeScalars.filter { $0.isASCII }.map(Character.init))
    }

    /// Mots ASCII d'une chaîne (lettres et chiffres).
    static func words(_ value: String) -> [String] {
        ascii(value)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// Initiale capitale, le reste tel quel (« McDowell ») — sauf un mot tout
    /// en capitales, ramené à la casse ordinaire (« FOUCAULT » → « Foucault »).
    static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        let rest = word.dropFirst()
        let shouting = word.count > 1 && word == word.uppercased()
        return first.uppercased() + (shouting ? rest.lowercased() : String(rest))
    }

    /// Nom de famille : le dernier mot séparé par des espaces, entier — un nom
    /// composé à trait d'union (« De-Tienne », « Merleau-Ponty ») reste d'un
    /// seul tenant.
    static func family(_ author: String) -> String? {
        guard let last = author.split(whereSeparator: \.isWhitespace).last else { return nil }
        let parts = words(String(last))
        guard !parts.isEmpty else { return nil }
        return parts.map(capitalized).joined()
    }

    /// Les quatre chiffres d'une année (« 1951 », « c. 1951 », « 1951-1953 »),
    /// sinon nil. Une année ancienne, seule dans le champ (« -350 » avant
    /// notre ère, « 14 »), rend ses chiffres sans signe : `Aristote350Traite`
    /// (le trait d'union est réservé à l'année d'édition).
    static func year(_ value: String?) -> String? {
        guard let value else { return nil }
        let bare = value.trimmingCharacters(in: .whitespaces)
        if let match = bare.wholeMatch(of: /-?(\d{1,3})/) { return String(match.1) }
        var digits = ""
        for character in value {
            if character.isNumber, character.isASCII {
                digits.append(character)
                if digits.count == 4 { return digits }
            } else {
                digits = ""
            }
        }
        return nil
    }

    /// La clé de base, sans désambiguïsation.
    public static func base(author: String?, year yearValue: String?, title: String) -> String {
        let family = author.flatMap(family) ?? "Anon"
        let titleWord = words(title)
            .first { $0.count > 1 && !stopwords.contains($0.lowercased()) }
            .map(capitalized) ?? ""
        return family + (year(yearValue) ?? "ND") + titleWord
    }

    /// Une clé libre à partir de `base`. `editionYear` départage d'abord ;
    /// ensuite `-b`, `-c`… La comparaison ignore la casse, comme la base.
    public static func unique(base: String, editionYear: String?, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        if !lowered.contains(base.lowercased()) { return base }
        if let edition = year(editionYear) {
            let candidate = "\(base)-\(edition)"
            if !lowered.contains(candidate.lowercased()) { return candidate }
        }
        for letter in "bcdefghijklmnopqrstuvwxyz" {
            let candidate = "\(base)-\(letter)"
            if !lowered.contains(candidate.lowercased()) { return candidate }
        }
        var n = 2
        while lowered.contains("\(base)-\(n)".lowercased()) { n += 1 }
        return "\(base)-\(n)"
    }

    /// Ce qu'une clé saisie à la main a le droit de contenir : ce que BibTeX,
    /// Pandoc et les URL acceptent sans échappement.
    public static func isValidManualKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 80 && key.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":")
        }
    }
}

public enum CiteKeyError: Error, Equatable, LocalizedError {
    case invalid(String)
    case taken(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let key): return "Clé invalide : « \(key) » (lettres, chiffres, - _ : seulement)."
        case .taken(let key): return "La clé « \(key) » est déjà prise par une autre édition."
        }
    }
}

extension EditionKey {
    /// Attribue une clé à chaque édition qui n'en a pas. Ne touche jamais une
    /// clé existante. Ordre déterministe (clé de base, édition datée ou non,
    /// identifiant) : d'une base à l'autre, la même édition reçoit la clé nue.
    ///
    /// Appelée dans la transaction d'ingestion : toute édition née d'un scan
    /// ressort avec sa clé.
    @discardableResult
    public static func assignMissing(_ db: Database, now: Date = Date()) throws -> Int {
        var taken = Set(try String.fetchAll(db, sql: "SELECT key FROM edition_key"))

        let rows = try Row.fetchAll(db, sql: """
            SELECT e.id AS editionId, e.year AS editionYear, w.date AS workDate, w.title AS title,
                   (SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                     WHERE wc.workId = w.id
                     ORDER BY (wc.role = 'author') DESC, wc.position LIMIT 1) AS author
            FROM edition e
            JOIN work w ON w.id = e.workId
            WHERE e.id NOT IN (SELECT editionId FROM edition_key)
            """)

        struct Pending { let id: UUID; let base: String; let editionYear: String?; let sort: String }
        let pending: [Pending] = rows.map { row in
            let id: UUID = row["editionId"]
            let workDate: String? = row["workDate"]
            let editionYear: String? = row["editionYear"]
            let title: String = row["title"]
            let author: String? = row["author"]
            // Année de l'œuvre si connue ; à défaut, celle que porte l'édition
            // (qui, importée d'un nom de fichier, EST l'année de l'œuvre).
            let original = workDate ?? editionYear
            let base = CiteKeyGenerator.base(author: author, year: original, title: title)
            // L'année d'édition ne départage que si elle diffère de l'originale.
            let distinctEditionYear = (workDate != nil && editionYear != workDate) ? editionYear : nil
            // À base égale, la clé nue va d'abord à l'édition sans année propre ;
            // les éditions datées prennent ensuite leur suffixe d'année.
            let rank = distinctEditionYear.map { "1\($0)" } ?? "0"
            return Pending(id: id, base: base, editionYear: distinctEditionYear,
                           sort: "\(base)\u{1}\(rank)\u{1}\(id.uuidString)")
        }

        for item in pending.sorted(by: { $0.sort < $1.sort }) {
            let key = CiteKeyGenerator.unique(base: item.base, editionYear: item.editionYear, taken: taken)
            try EditionKey(editionId: item.id, key: key, origin: .generated, dateAssigned: now).insert(db)
            taken.insert(key)
        }
        return pending.count
    }
}

extension EditionKey {
    /// Recalcule les clés **provisoires** des éditions d'une œuvre dont la
    /// fiche vient d'être corrigée. Les clés figées ou manuelles ne bougent pas.
    public static func refreshProvisional(forWork workId: UUID, _ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM edition_key
            WHERE origin = 'generated' AND editionId IN (SELECT id FROM edition WHERE workId = ?)
            """, arguments: [workId])
        try assignMissing(db)
    }

    /// Fige les clés provisoires (toutes, ou celles des éditions données) :
    /// à appeler au moment où elles sortent vers un outil de citation.
    @discardableResult
    public static func stabilize(_ db: Database, editionIds: [UUID]? = nil) throws -> Int {
        if let editionIds {
            for id in editionIds {
                try db.execute(sql: """
                    UPDATE edition_key SET origin = 'stable' WHERE origin = 'generated' AND editionId = ?
                    """, arguments: [id])
            }
        } else {
            try db.execute(sql: "UPDATE edition_key SET origin = 'stable' WHERE origin = 'generated'")
        }
        return db.changesCount
    }
}

extension CatalogStore {
    /// Attribue les clés manquantes (commande `ishtar keys`, et rattrapage des
    /// catalogues antérieurs à la v7).
    @discardableResult
    public func assignMissingKeys() async throws -> Int {
        try await db.pool.write { try EditionKey.assignMissing($0) }
    }

    /// La clé d'une édition, si elle en a une.
    public func key(forEdition editionId: UUID) async throws -> EditionKey? {
        try await db.pool.read { try EditionKey.fetchOne($0, key: editionId) }
    }

    /// Correction humaine d'une clé. Elle devient `manual` : aucune passe
    /// automatique ne la touchera plus.
    public func setKey(_ key: String, forEdition editionId: UUID) async throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CiteKeyGenerator.isValidManualKey(clean) else { throw CiteKeyError.invalid(clean) }
        try await db.pool.write { conn in
            if let owner = try UUID.fetchOne(conn, sql: """
                SELECT editionId FROM edition_key WHERE key = ? COLLATE NOCASE
                """, arguments: [clean]), owner != editionId {
                throw CiteKeyError.taken(clean)
            }
            try EditionKey(editionId: editionId, key: clean, origin: .manual).save(conn)
        }
    }
}
