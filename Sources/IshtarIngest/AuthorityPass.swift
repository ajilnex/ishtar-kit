import Foundation
import GRDB
import IshtarCatalog

/// Ce que la passe conclut pour un auteur.
public enum AuthorityDecision: Sendable, Equatable {
    /// Une seule personne d'IdRef a, parmi ses documents, un livre que la
    /// bibliothèque possède : c'est elle.
    case confirmed(IdRefCandidate, evidence: String)
    /// Des personnes plausibles, sans preuve décisive : à valider.
    case proposed([IdRefCandidate], evidence: String)
    case notFound
}

public struct AuthorityOutcome: Sendable {
    public let creatorId: UUID
    public let name: String
    public let decision: AuthorityDecision
}

/// Relie les auteurs du catalogue à leurs notices d'autorité (IdRef, puis la
/// BnF, VIAF, ISNI et Wikidata par les correspondances d'IdRef).
///
/// Règle de preuve, empruntée aux catalogueurs : un nom seul ne suffit pas
/// (IdRef connaît un Paul Ricœur et un Jean-Paul Ricoeur). Une notice est
/// **confirmée** quand un des livres de l'auteur dans la bibliothèque figure
/// parmi les documents que le Sudoc rattache à cette personne, et qu'aucune
/// autre personne candidate n'en a autant. Sinon, elle est seulement
/// **proposée**. Les liens déjà décidés ne sont jamais revus.
public enum AuthorityPass {
    /// Noms qui ne désignent personne.
    static let anonymous: Set<String> = ["anon", "anonyme", "anonymous", "collectif", "collective", "unknown", "inconnu", "divers", "various"]

    struct Author { let id: UUID; let name: String; let titles: [String] }

    /// Les auteurs à relier : ceux d'au moins une œuvre présente, sans lien
    /// IdRef (proposé, confirmé ou écarté).
    static func pendingAuthors(in db: CatalogDatabase) async throws -> [Author] {
        try await db.pool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT c.id AS id, c.name AS name, w.title AS title
                FROM creator c
                JOIN work_creator wc ON wc.creatorId = c.id AND wc.role = 'author'
                JOIN work w ON w.id = wc.workId
                WHERE EXISTS (SELECT 1 FROM edition e JOIN document d ON d.editionId = e.id
                              WHERE e.workId = w.id AND d.isMissing = 0)
                  AND NOT EXISTS (SELECT 1 FROM authority_link a
                                  WHERE a.entityType = 'creator' AND a.entityId = c.id AND a.scheme = 'idref')
                ORDER BY c.name
                """)
            var order: [UUID] = []
            var names: [UUID: String] = [:]
            var titles: [UUID: [String]] = [:]
            for row in rows {
                let id: UUID = row["id"]
                if names[id] == nil { order.append(id); names[id] = row["name"] }
                let title: String = row["title"]
                if !(titles[id]?.contains(title) ?? false) { titles[id, default: []].append(title) }
            }
            return order.compactMap { id in
                guard let name = names[id] else { return nil }
                let tokens = IdRefConnector.nameTokens(name)
                guard !tokens.isEmpty, !tokens.allSatisfy(anonymous.contains) else { return nil }
                return Author(id: id, name: name, titles: titles[id] ?? [])
            }
        }
    }

    // MARK: Preuve (pur)

    /// Deux titres désignent-ils le même livre ? Égalité des squelettes, ou
    /// l'un commence par l'autre quand le plus court est assez long pour ne
    /// pas être un hasard (« Minima moralia » / « Minima moralia : réflexions
    /// sur la vie mutilée »).
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        let x = TypographyRestorer.skeleton(a), y = TypographyRestorer.skeleton(b)
        guard x.count >= 4, y.count >= 4 else { return false }
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        return short.count >= 10 && long.hasPrefix(short)
    }

    /// Le premier de nos titres que le Sudoc rattache aussi à la personne.
    static func corroboration(ourTitles: [String], references: [IdRefReference]) -> String? {
        for title in ourTitles where references.contains(where: { sameTitle(title, $0.title) }) {
            return title
        }
        return nil
    }

    /// Le nom de famille d'une forme autorisée (« Ricœur, Paul (1913-2005) »
    /// → « ricoeur ») et celui d'un nom au long (« Paul Ricœur » → « ricoeur »).
    static func family(ofLabel label: String) -> String {
        TypographyRestorer.skeleton(label.components(separatedBy: ",").first ?? label)
    }

    /// « Theodor W. Adorno » → « adorno » ; « Nussbaum, Martha C. » (forme
    /// inversée, nom d'abord) → « nussbaum ».
    static func family(ofName name: String) -> String {
        let parts = name.components(separatedBy: ",")
        if parts.count == 2, parts[0].split(whereSeparator: \.isWhitespace).count <= 3 {
            return TypographyRestorer.skeleton(parts[0])
        }
        return TypographyRestorer.skeleton(name.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? name)
    }

    static func decide(name: String, candidates: [IdRefCandidate],
                       evidence: [String: String]) -> AuthorityDecision {
        let proven = candidates.filter { evidence[$0.ppn] != nil }
        if proven.count == 1, let title = evidence[proven[0].ppn] {
            return .confirmed(proven[0], evidence: "« \(title) » figure parmi ses documents dans le Sudoc")
        }
        if proven.count > 1 {
            return .proposed(proven, evidence: "plusieurs personnes ont un livre en commun avec la bibliothèque")
        }
        let family = family(ofName: name)
        let sameFamily = candidates.filter { Self.family(ofLabel: $0.label) == family }
        if sameFamily.count == 1 {
            return .proposed(sameFamily, evidence: "nom seul : aucun livre commun trouvé dans le Sudoc")
        }
        return .notFound
    }

    // MARK: Réseau

    /// Résout un auteur **par ses livres** d'abord : on cherche dans le Sudoc
    /// la notice d'un de ses titres ; la notice désigne l'auteur par son
    /// autorité IdRef. Une seule personne du bon nom de famille → confirmée.
    /// À défaut, repli sur la recherche du nom dans IdRef, prouvée par les
    /// documents que le Sudoc rattache à chaque candidat.
    static func resolve(_ author: Author, sudoc: SudocConnector, idref: IdRefConnector) async -> AuthorityDecision {
        let family = family(ofName: author.name)
        guard family.count >= 2 else { return .notFound }
        var tally: [String: (agent: SudocAgent, count: Int, title: String)] = [:]
        for title in author.titles.prefix(3) {
            guard let records = try? await sudoc.search(title: title, author: family) else { continue }
            for record in records where sameTitle(title, record.title) {
                for agent in record.agents where agent.isAuthor && TypographyRestorer.skeleton(agent.family) == family {
                    guard let ppn = agent.ppn, IdRefConnector.isPPN(ppn) else { continue }
                    tally[ppn] = (agent, (tally[ppn]?.count ?? 0) + 1, title)
                }
            }
            if !tally.isEmpty { break }
        }
        if let decision = decide(sudocTally: tally.mapValues { ($0.agent.label, $0.count, $0.title) }) {
            return decision
        }
        return await resolveByName(author, idref: idref)
    }

    /// Conclusion tirée des notices du Sudoc (pur) : une personne, ou une
    /// personne nettement majoritaire (au moins deux fois plus citée), est
    /// confirmée ; plusieurs à égalité sont proposées ; aucune → nil.
    static func decide(sudocTally tally: [String: (label: String, count: Int, title: String)]) -> AuthorityDecision? {
        let ranked = tally.sorted { $0.value.count > $1.value.count }
        guard let best = ranked.first else { return nil }
        if ranked.count == 1 || best.value.count >= 2 * ranked[1].value.count {
            return .confirmed(IdRefCandidate(ppn: best.key, label: best.value.label),
                              evidence: "auteur de « \(best.value.title) » dans le Sudoc")
        }
        return .proposed(ranked.map { IdRefCandidate(ppn: $0.key, label: $0.value.label) },
                         evidence: "plusieurs personnes de ce nom signent « \(best.value.title) » dans le Sudoc")
    }

    /// Repli : recherche du nom dans IdRef, puis examen des documents des
    /// candidats du même nom de famille (les cinq premiers).
    static func resolveByName(_ author: Author, idref: IdRefConnector) async -> AuthorityDecision {
        guard let candidates = try? await idref.search(name: author.name), !candidates.isEmpty else { return .notFound }
        let family = family(ofName: author.name)
        let examined = candidates.filter { Self.family(ofLabel: $0.label) == family }.prefix(5)
        var evidence: [String: String] = [:]
        for candidate in examined {
            guard let refs = try? await idref.references(ppn: candidate.ppn) else { continue }
            if let title = corroboration(ourTitles: author.titles, references: refs) {
                evidence[candidate.ppn] = title
            }
        }
        return decide(name: author.name, candidates: Array(examined), evidence: evidence)
    }

    /// Parcourt les auteurs en attente. Avec `apply`, chaque conclusion est
    /// écrite aussitôt (une interruption ne perd rien) ; les correspondances
    /// (BnF, VIAF, ISNI, Wikidata) suivent une notice confirmée.
    @discardableResult
    public static func run(in db: CatalogDatabase, apply: Bool, limit: Int? = nil,
                           sudoc: SudocConnector = SudocConnector(),
                           idref: IdRefConnector = IdRefConnector(),
                           wikidata: WikidataConnector = WikidataConnector(),
                           report: @Sendable (AuthorityOutcome) -> Void = { _ in }) async throws -> [AuthorityOutcome] {
        var authors = try await pendingAuthors(in: db)
        if let limit { authors = Array(authors.prefix(limit)) }
        let store = CatalogStore(db: db)
        var outcomes: [AuthorityOutcome] = []
        for author in authors {
            let decision = await resolve(author, sudoc: sudoc, idref: idref)
            let outcome = AuthorityOutcome(creatorId: author.id, name: author.name, decision: decision)
            outcomes.append(outcome)
            report(outcome)
            guard apply else { continue }
            switch decision {
            case let .confirmed(candidate, evidence):
                var links = [AuthorityLink(entityType: .creator, entityId: author.id, scheme: .idref,
                                           identifier: candidate.ppn, label: candidate.label,
                                           status: .confirmed, evidence: evidence)]
                let derived = "correspondance de la notice IdRef \(candidate.ppn)"
                for (scheme, identifier) in (try? await idref.alignments(ppn: candidate.ppn)) ?? [] {
                    links.append(AuthorityLink(entityType: .creator, entityId: author.id, scheme: scheme,
                                               identifier: identifier, status: .confirmed, evidence: derived))
                }
                if let qid = try? await wikidata.entity(forIdRef: candidate.ppn) {
                    links.append(AuthorityLink(entityType: .creator, entityId: author.id, scheme: .wikidata,
                                               identifier: qid, status: .confirmed, evidence: derived))
                }
                try await store.record(links)
            case let .proposed(candidates, evidence):
                try await store.record(candidates.map {
                    AuthorityLink(entityType: .creator, entityId: author.id, scheme: .idref,
                                  identifier: $0.ppn, label: $0.label, status: .proposed, evidence: evidence)
                })
            case .notFound:
                break
            }
        }
        return outcomes
    }
}
