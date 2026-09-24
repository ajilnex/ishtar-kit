import Foundation
import GRDB
import IshtarCatalog

/// Une fiche que les règles actuelles de l'entonnoir liraient autrement.
public struct ReidentificationProposal: Sendable {
    public let workId: UUID
    public let fileName: String
    public let current: (title: String, author: String?, year: String?)
    /// Titre relu (nil : inchangé).
    public let title: String?
    /// Année de l'œuvre relue ; l'année de l'édition ne bouge pas.
    public let workDate: String?
    /// Auteur donné à une œuvre qui n'en avait pas.
    public let authorForAnonymous: String?
    /// Nom d'auteur nettoyé (« Tite-Live (59 av.J.-C. – 17 av.J.-C.) » → « Tite-Live »).
    public let renamedAuthor: (creatorId: UUID, from: String, to: String)?
}

/// Ce que le vote des témoins décide pour l'auteur d'une œuvre.
public enum AttributionResolution: Sendable, Equatable {
    /// Même personne, nom plus complet (« Adin » → « Adin Steinsaltz »).
    case enrich(String)
    /// Une autre personne (« Sellars » → « Davidson »).
    case replace(String)
    /// Plusieurs personnes jointes (« Badiou-Roudinesco ») : à séparer.
    case split([String])
    /// Les témoins se contredisent : au Sudoc, ou à Aubin.
    case undecided
}

/// Trois témoins de l'auteur d'un livre : le nom de fichier (la convention
/// `Auteur_Année_Titre`, tenue à la main), les métadonnées que le fichier
/// porte, la fiche du catalogue. Quand ils ne s'accordent pas, c'est un
/// conflit d'attribution.
public struct AttributionConflict: Sendable {
    public let workId: UUID
    public let creatorId: UUID
    public let title: String
    public let catalogAuthor: String
    public let fileAuthor: String?
    public let embeddedAuthor: String?
    public let fileName: String
    public var resolution: AttributionResolution
    /// Rempli par `settle` quand le Sudoc a tranché.
    public var settledBySudoc = false
}

/// Réidentification : rejoue l'entonnoir mécanique (nom de fichier, puis
/// métadonnées embarquées) avec les règles d'aujourd'hui sur les fiches qui
/// ne sont pas passées par une main humaine (confiance haute : intouchables),
/// et propose ce qui a changé. Quand une règle est corrigée (années antiques,
/// dates collées aux noms…), cette passe répare le passé.
public enum Reidentification {
    struct Current {
        let workId: UUID, editionId: UUID, documentId: UUID
        let title: String, author: String?, authorId: UUID?, year: String?, workDate: String?,
            path: String, format: DocumentFormat
        let publisher: String?, language: String?, isbn13: String?, doi: String?
        var authorCount = 0
        var documentCount = 1
    }

    static func currentRecords(in db: CatalogDatabase) async throws -> [Current] {
        try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT w.id AS workId, e.id AS editionId, d.id AS documentId, w.title AS title, e.year AS year,
                       w.date AS workDate,
                       (SELECT wc.creatorId FROM work_creator wc
                         WHERE wc.workId = w.id AND wc.role = 'author' ORDER BY wc.position LIMIT 1) AS authorId,
                       (SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                         WHERE wc.workId = w.id AND wc.role = 'author' ORDER BY wc.position LIMIT 1) AS author,
                       d.filePath AS path, d.format AS format,
                       e.publisher AS publisher, e.language AS language, e.isbn13 AS isbn13, e.doi AS doi,
                       (SELECT count(*) FROM work_creator wc WHERE wc.workId = w.id AND wc.role = 'author') AS authorCount,
                       (SELECT count(*) FROM edition e2 JOIN document d2 ON d2.editionId = e2.id
                         WHERE e2.workId = w.id AND d2.isMissing = 0) AS documentCount
                FROM document d JOIN edition e ON e.id = d.editionId JOIN work w ON w.id = e.workId
                WHERE d.isMissing = 0 AND d.confidence != 'high' AND w.confidence != 'high'
                ORDER BY d.filePath
                """).compactMap { row in
                guard let format = DocumentFormat(rawValue: row["format"]) else { return nil }
                return Current(workId: row["workId"], editionId: row["editionId"], documentId: row["documentId"],
                               title: row["title"], author: row["author"], authorId: row["authorId"],
                               year: row["year"], workDate: row["workDate"],
                               path: row["path"], format: format, publisher: row["publisher"],
                               language: row["language"], isbn13: row["isbn13"], doi: row["doi"],
                               authorCount: row["authorCount"], documentCount: row["documentCount"])
            }
        }
    }

    public static func family(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        return AuthorityPass.family(ofName: TypographyRestorer.normalizedAuthor(name))
    }

    /// Mentions de vendeur collées aux titres : « (French Edition) », « (Kindle Edition) ».
    static func withoutVendorNoise(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\((?:[A-Za-z]+ )?Edition\)\s*$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Ce que la lecture d'aujourd'hui changerait (pur). nil si rien — ou si
    /// le nom de fichier désigne un autre auteur que la fiche : c'est alors un
    /// conflit d'attribution, qui ne se tranche pas mécaniquement.
    ///
    /// Règles (tirées des erreurs relevées par Aubin le 24/09) :
    /// - le nom de fichier `Auteur_Année_Titre` fait foi pour le titre et
    ///   l'année **de l'œuvre** ; l'année d'édition reste celle de l'édition ;
    /// - un titre qui est le même livre mieux écrit (accents, sous-titre) est
    ///   gardé ; les mentions de vendeur « (French Edition) » tombent ;
    /// - un auteur n'est jamais appauvri : « Chinua Achebe » ne redevient pas
    ///   « Achebe » ; il est seulement nettoyé (dates, forme inversée), ou
    ///   donné à une œuvre qui n'en avait pas.
    static func proposal(for c: Current, guess: MetadataGuess) -> ReidentificationProposal? {
        let cleanTitle = withoutVendorNoise(c.title)
        var title: String? = cleanTitle != c.title ? cleanTitle : nil
        let original = c.workDate ?? c.year
        var workDate: String?
        // Une œuvre à plusieurs fichiers (éditions réunies, formats, jumeaux) :
        // chaque nom de fichier ne parle que de son édition — l'année de
        // `Nietzsche_2011_…` n'est pas celle du *Gai Savoir*. Titre et année
        // de l'œuvre ne se relisent que sur une œuvre à un seul fichier.
        if c.documentCount <= 1 {
            if !guess.title.isEmpty, !AuthorityPass.sameTitle(cleanTitle, guess.title) { title = guess.title }
            workDate = guess.year.flatMap { $0 != original ? $0 : nil }
        }

        var authorForAnonymous: String?
        var renamed: (creatorId: UUID, from: String, to: String)?
        if let current = c.author, !current.isEmpty, let authorId = c.authorId {
            if let fileAuthor = guess.author, !family(fileAuthor).isEmpty, family(fileAuthor) != family(current) {
                return nil
            }
            let clean = TypographyRestorer.normalizedAuthor(current)
            if !clean.isEmpty, clean != current { renamed = (authorId, current, clean) }
        } else if let fileAuthor = guess.author.map(TypographyRestorer.normalizedAuthor), !fileAuthor.isEmpty {
            authorForAnonymous = fileAuthor
        }
        guard title != nil || workDate != nil || authorForAnonymous != nil || renamed != nil else { return nil }
        return ReidentificationProposal(
            workId: c.workId, fileName: URL(fileURLWithPath: c.path).lastPathComponent,
            current: (c.title, c.author, original), title: title, workDate: workDate,
            authorForAnonymous: authorForAnonymous, renamedAuthor: renamed)
    }

    // MARK: Vote des témoins (pur)

    static let placeholders: Set<String> = ["inconnu", "unknown", "anonyme", "anonymous", "anon", "nd", "sd", "divers", "various"]

    /// Mots qui trahissent le logiciel ou la machine qui a fabriqué le
    /// fichier, pas l'auteur du livre.
    static let machineWords: Set<String> = ["computers", "computer", "corporation", "microsoft", "adobe", "administrator",
                                            "admin", "user", "owner", "windows", "acrobat", "scanner", "calibre", "pdf"]

    public static func isPlaceholder(_ name: String?) -> Bool {
        guard let name else { return true }
        let s = TypographyRestorer.skeleton(name)
        if s.isEmpty || placeholders.contains(s) { return true }
        return nameWords(name).contains(where: machineWords.contains)
    }

    /// Les personnes d'un champ qui en nomme plusieurs (« Sami Naïr et
    /// Michael Löwy », « Hogrebe, Wolfram;Gabriel, Markus »), chacune remise
    /// en forme « Prénom Nom ». Vide si ce n'est pas une liste sûre.
    static func people(_ field: String?) -> [String] {
        guard let field else { return [] }
        // Dates de vie des catalogues, avant tout découpage.
        let cleaned = field.replacingOccurrences(of: #",\s*\d{3,4}\s*-\s*(\d{3,4}|\.{0,4})"#, with: "", options: .regularExpression)
        guard TypographyRestorer.isNameList(cleaned) else { return [] }
        var parts = [cleaned]
        for separator in [";", " et ", " and ", " & "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        var names = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Mentions de fonction : un traducteur n'est pas un auteur.
        names = names.filter { item in
            let lower = item.lowercased()
            return !["translated", "trad", "traduit", "edited", "ed.", "éd.", "préf", "introd"].contains { lower.hasPrefix($0) }
        }
        // « Gilles Deleuze, Félix Guattari » : des noms complets séparés par des virgules.
        if names.count == 1, case let commas = names[0].components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }),
           commas.count >= 2, commas.allSatisfy({ $0.split(whereSeparator: \.isWhitespace).count >= 2 }) {
            names = commas
        }
        // Dans une liste à points-virgules, une virgule est toujours une inversion.
        names = names.map { item in
            let c = item.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return c.count == 2 && !c[0].isEmpty && !c[1].isEmpty ? "\(c[1]) \(c[0])" : item
        }
        guard !names.isEmpty, names.allSatisfy({ !$0.contains(",") }),
              names.count >= 2 || parts.count >= 2 else { return [] }
        var seen: Set<String> = []
        return names.map(TypographyRestorer.normalizedAuthor).filter { !$0.isEmpty && seen.insert(family($0)).inserted }
    }

    /// Remet le nom de famille connu à la fin et rétablit la casse
    /// (« Lacan Jacques » → « Jacques Lacan », « laramee helene » →
    /// « Helene Laramee », « Nadia Kisukidi Yala » → « Nadia Yala Kisukidi »).
    static func familyLast(_ name: String, family known: String, fromFirst: Bool = false) -> String {
        var words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        if name == name.lowercased() {
            words = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        }
        // Le nom connu en tête est ambigu (« Lacan Jacques » est inversé, « Adin
        // Steinsaltz » ne l'est pas : le fichier avait retenu le prénom) : on
        // ne déplace que depuis le milieu.
        guard words.count >= (fromFirst ? 2 : 3), let i = words.firstIndex(where: { TypographyRestorer.skeleton($0) == known }),
              fromFirst || i > 0, i != words.count - 1 else { return words.joined(separator: " ") }
        let family = words.remove(at: i)
        return (words + [family]).joined(separator: " ")
    }

    /// Mots d'un nom, en squelette.
    static func nameWords(_ name: String) -> [String] {
        TypographyRestorer.normalizedAuthor(name)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map { TypographyRestorer.skeleton(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Deux noms désignent-ils la même personne ? Même nom de famille, ou
    /// l'un est une suite de mots de l'autre (« Adin » / « Adin Steinsaltz »,
    /// « DeVries » / « Willem A. de Vries », « Dante » / « Dante Alighieri »).
    public static func sameAuthor(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !isPlaceholder(a), !isPlaceholder(b) else { return false }
        if TypographyRestorer.isNameList(a) || TypographyRestorer.isNameList(b) { return false }
        if family(a) == family(b) { return true }
        func contains(_ long: [String], _ short: String) -> Bool {
            guard short.count >= 3, !long.isEmpty else { return false }
            for i in 0..<long.count {
                var run = ""
                for j in i..<long.count {
                    run += long[j]
                    if run == short { return true }
                    if run.count >= short.count { break }
                }
            }
            return false
        }
        let sa = TypographyRestorer.skeleton(a), sb = TypographyRestorer.skeleton(b)
        return contains(nameWords(b), sa) || contains(nameWords(a), sb)
    }

    /// Le nom le plus complet parmi ceux qui désignent la même personne.
    static func fullest(_ names: [String?]) -> String? {
        names.compactMap { $0 }
            .map(TypographyRestorer.normalizedAuthor)
            .filter { !isPlaceholder($0) && !TypographyRestorer.isNameList($0) && !$0.contains(",") }
            .filter { $0.split(whereSeparator: \.isWhitespace).count <= 5 }
            .max { a, b in
                let (wa, wb) = (a.split(whereSeparator: \.isWhitespace).count, b.split(whereSeparator: \.isWhitespace).count)
                return wa != wb ? wa < wb : TypographyRestorer.richness(a) < TypographyRestorer.richness(b)
            }
    }

    /// Co-auteurs joints par un trait d'union dans le nom de fichier
    /// (« Badiou-Roudinesco »), reconnus seulement si les métadonnées du
    /// fichier nomment chacun séparément — « Merleau-Ponty » reste un seul
    /// homme.
    static func coAuthors(_ file: String?, embedded: String?) -> [String]? {
        guard let file, let embedded, file.contains("-") else { return nil }
        let parts = file.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ $0.count >= 3 && $0.first?.isUppercase == true }) else { return nil }
        let words = Set(nameWords(embedded))
        guard parts.allSatisfy({ words.contains(TypographyRestorer.skeleton($0)) }),
              words.count >= parts.count * 2 else { return nil }
        return parts
    }

    /// Le vote (pur). nil : rien à faire.
    ///
    /// 1. Une fiche sans vrai nom (« Inconnu ») prend celui du fichier.
    /// 2. Même personne partout : on garde, en prenant le nom le plus complet.
    /// 3. Co-auteurs joints : à séparer.
    /// 4. Deux témoins contre un : ils l'emportent.
    /// 5. Une fiche que rien ne corrobore cède devant le nom de fichier, tenu
    ///    à la main (c'est le piège des fiches « Sellars » d'autrefois).
    /// 6. Trois témoins en désaccord : indécis (le Sudoc départagera).
    static func resolve(catalog rawCatalog: String, file: String?, embedded rawEmbedded: String?) -> AttributionResolution? {
        let file = isPlaceholder(file) ? nil : file
        let known = family(file ?? rawCatalog)
        // Les parties d'un nom de fichier à plusieurs auteurs (« Badiou-Roudinesco »,
        // « Hogrebe-et-al ») ; un seul élément pour un seul auteur.
        let fileParts = (file ?? "").split(separator: "-").map(String.init)
            .filter { !["et", "al", "etal"].contains($0.lowercased()) }
        let severalAnnounced = file.map { $0.lowercased().contains("-et-al") } ?? false || fileParts.count >= 2
        // Quand la fiche est remplacée, le nom de fichier (tenu à la main) dit
        // lequel des mots est le nom de famille : on peut le déplacer même depuis
        // la tête (« Robert Jean-Dominique » → « Jean-Dominique Robert »).
        func shaped(_ name: String) -> String { known.isEmpty ? name : familyLast(name, family: known, fromFirst: file != nil) }

        /// Une liste de personnes : on sépare si le fichier annonce plusieurs
        /// auteurs dont le premier y figure ; sinon on n'en garde que l'auteur
        /// que cite le fichier (les autres sont éditeurs, préfaciers,
        /// traducteurs — pas des auteurs, selon RDA). nil : liste étrangère.
        func fromList(_ list: [String]) -> (split: [String]?, single: String?)? {
            let families = list.map { family($0) }
            if severalAnnounced, let first = fileParts.first, families.contains(TypographyRestorer.skeleton(first)) {
                return (list, nil)
            }
            if let match = list.first(where: { family($0) == known || sameAuthor($0, file) }) { return (nil, match) }
            return nil
        }

        var embedded = isPlaceholder(rawEmbedded) ? nil : rawEmbedded
        let embeddedPeople = people(rawEmbedded)
        if embeddedPeople.count == 1 { embedded = embeddedPeople[0] }
        if embeddedPeople.count >= 2 {
            guard let r = fromList(embeddedPeople) else { return nil }
            if let split = r.split { return .split(split) }
            embedded = r.single
        }
        let catalog: String? = isPlaceholder(rawCatalog) ? nil : rawCatalog
        let catalogPeople = people(rawCatalog)
        if catalogPeople.count == 1, catalogPeople[0] != rawCatalog {
            // Une liste qui ne nomme qu'un auteur une fois les fonctions écartées.
            return .replace(catalogPeople[0])
        }
        if catalogPeople.count >= 2 {
            guard file != nil, let r = fromList(catalogPeople) else { return .undecided }
            if let split = r.split { return .split(split) }
            guard let single = r.single else { return .undecided }
            return .replace(shaped(fullest([single, embedded].filter { sameAuthor(single, $0) }) ?? single))
        }
        // Co-auteurs joints dans le nom de fichier, dont le premier est connu du fichier.
        if let split = coAuthors(file, embedded: embedded) { return .split(split) }
        if let file, file.contains("-"), let embedded,
           case let parts = file.split(separator: "-").map(String.init)
               .filter({ !["et", "al", "etal"].contains($0.lowercased()) }), parts.count >= 1,
           sameAuthor(parts[0], embedded), !sameAuthor(file, embedded) {
            return .split([shaped(fullest([parts[0], embedded]) ?? parts[0])] + parts.dropFirst().map { $0 })
        }

        guard let catalog else {
            guard let file else { return nil }
            let best = sameAuthor(file, embedded) ? fullest([file, embedded]) ?? file : file
            return .replace(shaped(best))
        }
        let agreesFile = file == nil || sameAuthor(catalog, file)
        let agreesEmbedded = embedded == nil || sameAuthor(catalog, embedded)
        if agreesFile && (agreesEmbedded || file != nil) {
            let witnesses = [catalog] + [file, embedded].filter { sameAuthor(catalog, $0) }
            // Même personne : le nom de fichier peut avoir retenu un prénom
            // (« Adin » pour Adin Steinsaltz) — on ne déplace rien depuis la tête.
            guard let raw = fullest(witnesses) else { return nil }
            let best = familyLast(raw, family: known)
            if let first = best.split(whereSeparator: \.isWhitespace).first,
               TypographyRestorer.skeleton(String(first)) == family(catalog),
               best.split(whereSeparator: \.isWhitespace).count >= 2 { return nil }
            let words = { (n: String) in n.split(whereSeparator: \.isWhitespace).count }
            guard best != catalog,
                  words(best) > words(catalog) || TypographyRestorer.richness(best) > TypographyRestorer.richness(catalog)
            else { return nil }
            return .enrich(best)
        }
        guard let file else { return nil }       // pas de nom de fichier lisible : on ne touche pas
        if let embedded, sameAuthor(file, embedded) { return .replace(shaped(fullest([file, embedded]) ?? file)) }
        if let embedded, sameAuthor(catalog, embedded) { return .undecided }
        if embedded == nil { return .replace(file) }
        return .undecided
    }

    /// Les relectures mécaniques et les conflits d'attribution.
    public static func examine(in db: CatalogDatabase) async throws -> (proposals: [ReidentificationProposal], conflicts: [AttributionConflict]) {
        var proposals: [ReidentificationProposal] = []
        var conflicts: [AttributionConflict] = []
        var seenWorks: Set<UUID> = []
        for c in try await currentRecords(in: db) {
            let url = URL(fileURLWithPath: c.path)
            let guess = Ingestor.mechanicalGuess(fileName: url.lastPathComponent, fileURL: url, format: c.format)
            if guess.confidence == .structured, !seenWorks.contains(c.workId),
               let p = proposal(for: c, guess: guess) {
                proposals.append(p)
                seenWorks.insert(c.workId)
                continue
            }
            // Conflit : les témoins de l'auteur ne s'accordent pas.
            // Plusieurs fichiers d'une même œuvre dont les noms se contredisent :
            // l'un ment forcément ; seul le contenu tranche (ContentCheck, lecture).
            guard c.authorCount == 1, c.documentCount <= 1, let current = c.author, let creatorId = c.authorId,
                  !seenWorks.contains(c.workId) else { continue }
            let fileAuthor = guess.confidence == .structured ? guess.author : nil
            let embedded = EmbeddedMetadata.read(fileURL: url, format: c.format)
            // Des métadonnées qui parlent d'un autre titre ne témoignent de rien
            // (« NEC Computers International », « Administrator »…).
            let embeddedAuthor = embedded.flatMap { e in
                AuthorityPass.sameTitle(e.title, c.title) || AuthorityPass.sameTitle(e.title, guess.title) ? e.author : nil
            }
            if let resolution = resolve(catalog: current, file: fileAuthor, embedded: embeddedAuthor) {
                conflicts.append(AttributionConflict(
                    workId: c.workId, creatorId: creatorId, title: c.title, catalogAuthor: current,
                    fileAuthor: fileAuthor, embeddedAuthor: embeddedAuthor.map(TypographyRestorer.normalizedAuthor),
                    fileName: url.lastPathComponent, resolution: resolution))
                seenWorks.insert(c.workId)
            }
        }
        return (proposals, conflicts)
    }

    /// Départage les conflits indécis par le Sudoc (réseau, geste
    /// volontaire) : le nom que le catalogue collectif associe à ce titre
    /// l'emporte ; si les deux ou aucun ne sont confirmés, le conflit reste
    /// ouvert.
    public static func settle(_ conflicts: [AttributionConflict], sudoc: SudocConnector = SudocConnector()) async -> [AttributionConflict] {
        var settled: [AttributionConflict] = []
        for var conflict in conflicts {
            if conflict.resolution == .undecided {
                // La forme du nom que retient le Sudoc (« Aristote », « Lucrèce »).
                var confirmed: [String] = []
                for candidate in [conflict.catalogAuthor, conflict.fileAuthor, conflict.embeddedAuthor].compactMap({ $0 }) {
                    let family = family(candidate)
                    guard !family.isEmpty else { continue }
                    let records = (try? await sudoc.search(title: conflict.title, author: family)) ?? []
                    let agent = records.lazy.filter { AuthorityPass.sameTitle($0.title, conflict.title) }
                        .compactMap { r in r.agents.first { $0.isAuthor && TypographyRestorer.skeleton($0.family) == family } }
                        .first
                    if let agent {
                        let name = [agent.given, agent.family].compactMap { $0 }.joined(separator: " ")
                        if !confirmed.contains(where: { sameAuthor($0, name) }) { confirmed.append(name) }
                    }
                }
                if confirmed.count == 1 {
                    let winner = confirmed[0]
                    conflict.resolution = sameAuthor(winner, conflict.catalogAuthor) ? .enrich(winner) : .replace(winner)
                    conflict.settledBySudoc = true
                    if case .enrich(let name) = conflict.resolution, name == conflict.catalogAuthor { conflict.resolution = .undecided }
                }
            }
            settled.append(conflict)
        }
        return settled
    }

    /// Applique les relectures. Rend le nombre d'œuvres modifiées.
    @discardableResult
    public static func apply(_ proposals: [ReidentificationProposal], to db: CatalogDatabase) async throws -> Int {
        let store = CatalogStore(db: db)
        var n = 0
        for p in proposals {
            var changed = try await store.reidentify(workId: p.workId, title: p.title, workDate: p.workDate,
                                                     authorForAnonymous: p.authorForAnonymous)
            if let r = p.renamedAuthor {
                try await store.renameCreator(r.creatorId, to: r.to)
                changed = true
            }
            if changed { n += 1 }
        }
        return n
    }

    /// Applique les attributions décidées (les indécises restent). Un nom
    /// enrichi renomme la personne partout ; un auteur remplacé ne touche que
    /// cette œuvre.
    @discardableResult
    public static func apply(attributions conflicts: [AttributionConflict], to db: CatalogDatabase) async throws -> Int {
        let store = CatalogStore(db: db)
        var n = 0
        for c in conflicts {
            switch c.resolution {
            case .enrich(let name):
                try await store.renameCreator(c.creatorId, to: name)
            case .replace(let name):
                guard try await store.setAuthors(workId: c.workId, [name]) else { continue }
            case .split(let names):
                guard try await store.setAuthors(workId: c.workId, names) else { continue }
            case .undecided:
                continue
            }
            n += 1
        }
        return n
    }
}
