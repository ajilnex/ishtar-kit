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

    /// Particules qui, en capitale, font partie du nom (« Ursula K. Le Guin »,
    /// « André De Tienne ») — en minuscule, non (« Michel de Montaigne »).
    /// La même règle que l'étiquette des fichiers (`FileLabel.family`).
    static let capitalParticles: Set<String> = ["De", "Van", "Le", "La", "Du", "Di", "Da", "Del", "Des", "Von", "Ten", "Ter"]

    /// Articles d'une épithète, en minuscule (« Pline le Jeune », « Ivan der Schreckliche »).
    static let epithetArticles: Set<String> = ["le", "la", "les", "the", "der", "die", "das", "il", "lo", "el"]

    /// Nom de famille. La forme de classement fait foi quand elle existe
    /// (« Pline le Jeune » → `PlineLeJeune`, « Sun Tzu » → `SunTzu`,
    /// « Viveiros de Castro, Eduardo » → `ViveirosDeCastro`) : sans elle, une
    /// épithète passait pour un nom (`Jeune100Lettres`, 04/10). Sinon, le
    /// dernier mot séparé par des espaces, entier — un nom composé à trait
    /// d'union (« De-Tienne », « Merleau-Ponty ») reste d'un seul tenant — avec
    /// sa particule en capitale.
    static func family(_ author: String, sortName: String? = nil) -> String? {
        if let sortName, let head = sortName.components(separatedBy: ",").first,
           !head.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = words(head)
            if !parts.isEmpty { return parts.map(capitalized).joined() }
        }
        let tokens = author.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = tokens.last else { return nil }
        var name = last
        let n = tokens.count
        if n >= 2, capitalParticles.contains(tokens[n - 2]) { name = tokens[n - 2] + " " + last }
        // Une épithète n'est pas un nom de famille : « Pline le Jeune », « Pline
        // l'Ancien », « Alexandre le Grand » se citent en entier — sauf derrière
        // une particule (« Jean de la Bruyère » → `LaBruyere`).
        let isArticle = { (w: String) in epithetArticles.contains(w) }
        if n >= 3, isArticle(tokens[n - 2]) {
            name = ["de", "du", "des", "d'", "d’"].contains(tokens[n - 3]) ? tokens[n - 2] + " " + last : tokens.joined(separator: " ")
        } else if n >= 2, last.hasPrefix("l'") || last.hasPrefix("l’") {
            name = tokens.joined(separator: " ")
        }
        let parts = words(name)
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
    public static func base(author: String?, sortName: String? = nil, year yearValue: String?, title: String) -> String {
        let name = author.flatMap { family($0, sortName: sortName) } ?? "Anon"
        return name + (year(yearValue) ?? "ND") + (titleWords(title).first ?? "")
    }

    /// Chiffre romain de tome ou de partie (i à xxxix) : « Tome II ».
    static func isRoman(_ word: String) -> Bool {
        word.lowercased().wholeMatch(of: /x{0,3}(ix|iv|v?i{0,3})/) != nil && !word.isEmpty
    }

    /// Les mots significatifs d'un titre, capitalisés : sans articles ni mots
    /// d'une lettre, mais avec les numéros (« Anna Karénine, Tome II » →
    /// Anna, Karenine, Tome, II).
    static func titleWords(_ title: String) -> [String] {
        words(title).compactMap { word in
            if isRoman(word) { return word.uppercased() }
            if word.allSatisfy(\.isNumber) { return word }
            guard word.count > 1, !stopwords.contains(word.lowercased()) else { return nil }
            return capitalized(word)
        }
    }

    /// Le mot qui distingue un titre d'autres titres de même clé de base :
    /// le dernier mot du plus court début de titre que nul autre ne partage.
    /// « Wilfrid Sellars: Fusing the Images » face à « Wilfrid Sellars on
    /// Truth » → « Fusing ». nil si le titre est le début d'un autre (il garde
    /// la clé nue) ou si rien ne le distingue.
    static func distinguishing(_ mine: [String], from others: [[String]]) -> String? {
        let lower = mine.map { $0.lowercased() }
        let otherLists = others.map { $0.map { $0.lowercased() } }
        guard lower.count > 1 else { return nil }
        for k in 2...lower.count {
            let prefix = Array(lower.prefix(k))
            if !otherLists.contains(where: { Array($0.prefix(k)) == prefix }) {
                // « Tome » seul ne dit rien : on y joint son numéro (« Tome1 »).
                if ["tome", "vol", "volume", "band", "livre", "book", "part", "partie"].contains(lower[k - 1]), k < mine.count {
                    return mine[k - 1] + mine[k]
                }
                return mine[k - 1]
            }
        }
        return nil
    }

    /// Une clé libre à partir de `base`. `editionYear` départage d'abord ;
    /// ensuite `-b`, `-c`… La comparaison ignore la casse, comme la base.
    public static func unique(base: String, editionYear: String?, language: String? = nil, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        if !lowered.contains(base.lowercased()) { return base }
        if let edition = year(editionYear) {
            let candidate = "\(base)-\(edition)"
            if !lowered.contains(candidate.lowercased()) { return candidate }
        }
        // Une traduction se distingue par sa langue : `Cesaire1950Discours-en`.
        if let language, language.count == 2, language.allSatisfy(\.isLetter) {
            let candidate = "\(base)-\(language.lowercased())"
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
        // Une clé retirée n'est jamais redonnée : elle renvoie pour toujours à
        // son édition (pierre tombale).
        var taken = Set(try String.fetchAll(db, sql: "SELECT key FROM edition_key UNION ALL SELECT key FROM edition_key_retired"))

        let rows = try Row.fetchAll(db, sql: """
            SELECT e.id AS editionId, e.workId AS workId, e.year AS editionYear, w.date AS workDate, w.title AS title,
                   e.language AS language, w.originalLanguage AS originalLanguage,
                   (SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                     WHERE wc.workId = w.id
                     ORDER BY (wc.role = 'author') DESC, wc.position LIMIT 1) AS author,
                   (SELECT c.sortName FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                     WHERE wc.workId = w.id
                     ORDER BY (wc.role = 'author') DESC, wc.position LIMIT 1) AS sortName
            FROM edition e
            JOIN work w ON w.id = e.workId
            WHERE e.id NOT IN (SELECT editionId FROM edition_key)
            """)

        // Les titres des œuvres qui portent déjà une clé, par clé de base : un
        // nouveau livre de même base doit s'en distinguer par son titre.
        var existing: [String: [(work: UUID, title: String)]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT k.key AS key, e.workId AS workId, w.title AS title
            FROM edition_key k JOIN edition e ON e.id = k.editionId JOIN work w ON w.id = e.workId
            """) {
            let key: String = row["key"]
            let base = String(key.split(separator: "-").first ?? Substring(key)).lowercased()
            existing[base, default: []].append((row["workId"], row["title"]))
        }

        struct Pending { let id: UUID; var base: String; let editionYear: String?; var sort: String; let work: UUID; let title: String; let rank: String; let language: String? }
        var pending: [Pending] = rows.map { row in
            let id: UUID = row["editionId"]
            let workDate: String? = row["workDate"]
            let editionYear: String? = row["editionYear"]
            let title: String = row["title"]
            let author: String? = row["author"]
            // Année de l'œuvre si connue ; à défaut, celle que porte l'édition
            // (qui, importée d'un nom de fichier, EST l'année de l'œuvre).
            let original = workDate ?? editionYear
            let base = CiteKeyGenerator.base(author: author, sortName: row["sortName"], year: original, title: title)
            // L'année d'édition ne départage que si elle diffère de l'originale.
            let distinctEditionYear = (workDate != nil && editionYear != workDate) ? editionYear : nil
            // À base égale, la clé nue va d'abord à l'édition sans année propre ;
            // les éditions datées prennent ensuite leur suffixe d'année.
            // L'édition dans la langue originale d'abord : c'est elle qui porte
            // la clé nue ; les traductions prennent leur année ou leur langue.
            let language: String? = row["language"]
            let originalLanguage: String? = row["originalLanguage"]
            let translation = originalLanguage != nil && language != nil && language != originalLanguage
            let rank = (translation ? "1" : "0") + (distinctEditionYear.map { "1\($0)" } ?? "0")
            return Pending(id: id, base: base, editionYear: distinctEditionYear,
                           sort: "\(base)\u{1}\(rank)\u{1}\(id.uuidString)",
                           work: row["workId"], title: title, rank: rank, language: translation ? language : nil)
        }

        // Deux livres différents de même base : chacun prend le mot de titre
        // qui le distingue (`Rosenberg2007WilfridFusing`,
        // `Rosenberg2007WilfridTruth`) plutôt qu'un « -b » qui fait croire à un
        // doublon. Les éditions d'une même œuvre gardent l'année d'édition.
        let byBase = Dictionary(grouping: pending.indices, by: { pending[$0].base.lowercased() })
        for (base, indices) in byBase {
            var titles: [UUID: String] = [:]
            for i in indices { titles[pending[i].work] = pending[i].title }
            for owner in existing[base] ?? [] { titles[owner.work] = owner.title }
            guard titles.count > 1 else { continue }
            for i in indices {
                let others = titles.filter { $0.key != pending[i].work }.map { CiteKeyGenerator.titleWords($0.value) }
                if let word = CiteKeyGenerator.distinguishing(CiteKeyGenerator.titleWords(pending[i].title), from: others) {
                    pending[i].base += word
                    pending[i].sort = "\(pending[i].base)\u{1}\(pending[i].rank)\u{1}\(pending[i].id.uuidString)"
                }
            }
        }

        for item in pending.sorted(by: { $0.sort < $1.sort }) {
            let key = CiteKeyGenerator.unique(base: item.base, editionYear: item.editionYear, language: item.language, taken: taken)
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

    /// Recalcule toutes les clés **provisoires** avec les règles du moment
    /// (les clés figées ou manuelles ne bougent pas). Rend le nombre de clés
    /// qui ont changé.
    @discardableResult
    public func recomputeProvisionalKeys() async throws -> Int {
        try await db.pool.write { conn in
            let before = Dictionary(uniqueKeysWithValues: try Row.fetchAll(conn, sql: "SELECT editionId, key FROM edition_key WHERE origin = 'generated'")
                .map { ($0["editionId"] as UUID, $0["key"] as String) })
            try conn.execute(sql: "DELETE FROM edition_key WHERE origin = 'generated'")
            try EditionKey.assignMissing(conn)
            let after = try Row.fetchAll(conn, sql: "SELECT editionId, key FROM edition_key WHERE origin = 'generated'")
            return after.filter { before[$0["editionId"] as UUID] != ($0["key"] as String) }.count
        }
    }

    /// Fige les clés données (elles sortent vers un outil de citation) : dès
    /// lors, aucune passe ne les change plus. Rend le nombre de clés figées.
    @discardableResult
    public func stabilizeKeys(_ keys: [String]) async throws -> Int {
        try await db.pool.write { conn in
            var n = 0
            for key in keys {
                try conn.execute(sql: "UPDATE edition_key SET origin = 'stable' WHERE origin = 'generated' AND key = ?", arguments: [key])
                n += conn.changesCount
            }
            return n
        }
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

// MARK: - Clés justes (04/10/2026)

extension CiteKeyGenerator {
    /// Une clé est juste si elle dit ce que dit la fiche : sa base (famille,
    /// année, premier mot du titre), suivie au plus d'un mot du titre qui la
    /// distingue (`Rosenberg2007WilfridFusing`, `Long1987HellenisticVolume1`),
    /// puis d'un suffixe d'édition (`-2003`, `-en`, `-b`). La casse est ignorée.
    public static func agrees(key: String, author: String?, sortName: String?, year: String?, title: String) -> Bool {
        let stem = String(key.split(separator: "-", maxSplits: 1).first ?? Substring(key)).lowercased()
        let expected = base(author: author, sortName: sortName, year: year, title: title).lowercased()
        guard stem.hasPrefix(expected) else { return false }
        let rest = String(stem.dropFirst(expected.count))
        if rest.isEmpty { return true }
        let words = titleWords(title).map { $0.lowercased() }
        for i in words.indices.dropFirst() {
            if rest == words[i] { return true }
            if i + 1 < words.count, rest == words[i] + words[i + 1] { return true }
        }
        return false
    }
}

extension EditionKey {
    /// Une clé qui ne dit plus ce que dit sa fiche.
    public struct Disagreement: Sendable, Equatable {
        public let editionId: UUID
        public let key: String
        public let origin: Origin
        /// La base que donnerait la fiche d'aujourd'hui.
        public let expected: String
    }

    /// Un remplacement : l'ancienne clé, devenue pierre tombale, et la nouvelle.
    public struct Change: Sendable, Equatable, Codable {
        public let editionId: UUID
        public let old: String
        public let new: String
        /// Vrai : l'ancienne avait pu sortir (figée) et reste une pierre tombale.
        public let retired: Bool
    }

    /// Les clés (hors clés manuelles) qui ne disent plus ce que dit leur fiche
    /// — auteur, année ou premier mot du titre (« Jeune100Lettres » pour Pline le
    /// Jeune, « Kiryushchenko1974Diagrams » pour un livre de 2023).
    public static func disagreeing(_ db: Database) throws -> [Disagreement] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT k.editionId AS editionId, k.key AS key, k.origin AS origin,
                   e.year AS editionYear, w.date AS workDate, w.title AS title,
                   (SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                     WHERE wc.workId = w.id ORDER BY (wc.role = 'author') DESC, wc.position LIMIT 1) AS author,
                   (SELECT c.sortName FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                     WHERE wc.workId = w.id ORDER BY (wc.role = 'author') DESC, wc.position LIMIT 1) AS sortName
            FROM edition_key k JOIN edition e ON e.id = k.editionId JOIN work w ON w.id = e.workId
            WHERE k.origin <> 'manual'
            ORDER BY k.key
            """)
        return rows.compactMap { row in
            let key: String = row["key"]
            let workDate: String? = row["workDate"]
            let editionYear: String? = row["editionYear"]
            let year = workDate ?? editionYear
            let author: String? = row["author"]
            let sortName: String? = row["sortName"]
            let title: String = row["title"]
            guard !CiteKeyGenerator.agrees(key: key, author: author, sortName: sortName, year: year, title: title) else { return nil }
            return Disagreement(editionId: row["editionId"], key: key, origin: row["origin"],
                                expected: CiteKeyGenerator.base(author: author, sortName: sortName, year: year, title: title))
        }
    }

    /// Remplace les clés des éditions données par celles que donnent leurs
    /// fiches. Une clé figée devient une pierre tombale qui renvoie à la
    /// nouvelle, elle-même figée (elle remplace une clé qui a pu être citée) ;
    /// les pierres plus anciennes qui menaient à l'ancienne mènent désormais à
    /// la nouvelle. Une clé provisoire (jamais sortie) est seulement recalculée.
    /// Les clés manuelles ne bougent jamais.
    @discardableResult
    public static func replace(_ db: Database, editionIds: [UUID], reason: String, now: Date = Date()) throws -> [Change] {
        var olds: [UUID: EditionKey] = [:]
        for id in editionIds {
            if let key = try EditionKey.fetchOne(db, key: id), key.origin != .manual { olds[id] = key }
        }
        for (id, key) in olds {
            if key.origin != .generated {
                try RetiredKey(key: key.key, editionId: id, replacedBy: nil, reason: reason, dateRetired: now).save(db)
            }
            _ = try key.delete(db)
        }
        try assignMissing(db, now: now)
        var changes: [Change] = []
        for (id, old) in olds.sorted(by: { $0.value.key < $1.value.key }) {
            guard var fresh = try EditionKey.fetchOne(db, key: id) else { continue }
            if old.origin != .generated {
                fresh.origin = old.origin == .manual ? .manual : .stable
                try fresh.update(db)
                try db.execute(sql: "UPDATE edition_key_retired SET replacedBy = ? WHERE key = ? COLLATE NOCASE OR replacedBy = ? COLLATE NOCASE",
                               arguments: [fresh.key, old.key, old.key])
            }
            changes.append(Change(editionId: id, old: old.key, new: fresh.key, retired: old.origin != .generated))
        }
        return changes
    }
}

extension CatalogStore {
    /// Les clés qui ne disent plus ce que dit leur fiche.
    public func disagreeingKeys() async throws -> [EditionKey.Disagreement] {
        try await db.pool.read { try EditionKey.disagreeing($0) }
    }

    /// Remplace les clés des éditions données ; `dryRun` : calcule sans rien écrire.
    public func replaceKeys(editionIds: [UUID], reason: String, dryRun: Bool) async throws -> [EditionKey.Change] {
        try await db.pool.write { conn in
            var changes: [EditionKey.Change] = []
            try conn.inSavepoint {
                changes = try EditionKey.replace(conn, editionIds: editionIds, reason: reason)
                return dryRun ? .rollback : .commit
            }
            return changes
        }
    }
}
