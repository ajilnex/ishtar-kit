import Foundation
import GRDB
import IshtarCatalog

/// La boucle de citations vérifiées (principe cardinal, invariant n° 6) :
/// « la vérité a une page ». Le démon cite avec un marqueur machine
/// `[[cite:<uuid>|p=<page>|"<mots exacts>"]]` — vérifiable exactement contre le
/// texte extrait du catalogue, sans résolution floue. Cascade héritée du
/// prototype : source → page → verbatim → « trouvé page X au lieu de Y ».
public struct CitationVerifier: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    // MARK: Extraction des marqueurs

    public struct Citation: Sendable, Equatable {
        public let documentId: UUID
        public let page: Int
        /// Les mots exacts annoncés (optionnels mais fortement demandés au modèle).
        public let quote: String?
        /// Le marqueur brut, pour le remplacer au rendu.
        public let raw: String
    }

    /// `[[cite:UUID|p=N|"extrait"]]` — l'extrait est optionnel.
    static let pattern = #"\[\[cite:([0-9a-fA-F-]{36})\|p=(\d+)(?:\|"([^"\n]{0,300})")?\]\]"#

    public static func extract(from text: String) -> [Citation] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard let id = UUID(uuidString: ns.substring(with: match.range(at: 1))),
                      let page = Int(ns.substring(with: match.range(at: 2)))
                else { return nil }
                let quote = match.range(at: 3).location != NSNotFound
                    ? ns.substring(with: match.range(at: 3)) : nil
                return Citation(documentId: id, page: page, quote: quote,
                                raw: ns.substring(with: match.range))
            }
    }

    // MARK: Verdicts

    public enum Verdict: Sendable, Equatable {
        /// Vérifiée : le document existe, la page aussi, l'extrait s'y trouve.
        case valid(title: String)
        /// Le document n'existe pas dans la bibliothèque.
        case invalidSource
        /// La page dépasse la pagination réelle du texte extrait.
        case pageOutOfRange(title: String, maxPage: Int)
        /// L'extrait n'est nulle part dans ce document.
        case quoteNotFound(title: String)
        /// L'extrait existe, mais à une autre page — le feedback le plus utile.
        case foundElsewhere(title: String, actualPage: Int)
        /// Le texte de ce document n'est pas extrait : invérifiable (averti,
        /// jamais renvoyé en correction — le modèle n'y peut rien).
        case noTextAvailable(title: String)

        public var isFailure: Bool {
            switch self {
            case .valid, .noTextAvailable: false
            default: true
            }
        }
    }

    public struct Check: Sendable {
        public let citation: Citation
        public let verdict: Verdict
        /// Le titre à afficher (« document inconnu » si la source est invalide).
        public var title: String {
            switch verdict {
            case .valid(let t), .pageOutOfRange(let t, _), .quoteNotFound(let t),
                 .foundElsewhere(let t, _), .noTextAvailable(let t): t
            case .invalidSource: "document inconnu"
            }
        }
    }

    // MARK: Vérification

    public func verify(text: String) async -> [Check] {
        var checks: [Check] = []
        for citation in Self.extract(from: text) {
            checks.append(Check(citation: citation,
                                verdict: await verdict(for: citation)))
        }
        return checks
    }

    private func verdict(for citation: Citation) async -> Verdict {
        // 1. La source existe-t-elle ?
        let info: (title: String, maxPage: Int?)? = try? await db.pool.read { conn in
            guard let title = try String.fetchOne(conn, sql: """
                SELECT w.title FROM document d
                JOIN edition e ON e.id = d.editionId
                JOIN work w ON w.id = e.workId
                WHERE d.id = ?
                """, arguments: [citation.documentId]) else { return nil }
            let maxPage = try Int.fetchOne(conn, sql: """
                SELECT MAX(pageNumber) FROM document_page WHERE documentId = ?
                """, arguments: [citation.documentId])
            return (title, maxPage)
        }
        guard let info else { return .invalidSource }

        // 2. Le texte est-il extrait ? Sinon : invérifiable, pas corrigeable.
        guard let maxPage = info.maxPage else { return .noTextAvailable(title: info.title) }

        // 3. La page est-elle dans les bornes réelles ?
        guard citation.page >= 1, citation.page <= maxPage else {
            return .pageOutOfRange(title: info.title, maxPage: maxPage)
        }

        // 4. Verbatim (normalisé) sur la page citée, sinon ailleurs dans le
        // document — « trouvé page X » corrige bien mieux que « non trouvé ».
        guard let quote = citation.quote,
              !quote.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Pas d'extrait fourni : source + page suffisent (citation faible
            // mais pas fausse).
            return .valid(title: info.title)
        }
        let needle = Self.normalized(quote)
        guard needle.count >= 8 else { return .valid(title: info.title) }

        let pages: [(Int, String)] = (try? await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT pageNumber, content FROM document_page
                WHERE documentId = ? ORDER BY pageNumber
                """, arguments: [citation.documentId])
                .map { ($0["pageNumber"], $0["content"]) }
        }) ?? []

        if let cited = pages.first(where: { $0.0 == citation.page }),
           Self.normalized(cited.1).contains(needle) {
            return .valid(title: info.title)
        }
        if let elsewhere = pages.first(where: { $0.0 != citation.page
            && Self.normalized($0.1).contains(needle) }) {
            return .foundElsewhere(title: info.title, actualPage: elsewhere.0)
        }
        return .quoteNotFound(title: info.title)
    }

    /// Minuscules, diacritiques repliées, tout séparateur réduit à un espace :
    /// le verbatim survit à l'OCR approximatif et aux césures.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive,
                               .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Feedback de correction (catégorisé, hérité du prototype)

    /// Le message renvoyé au modèle pour qu'il corrige — uniquement les échecs
    /// corrigeables.
    public static func feedback(for checks: [Check]) -> String {
        let lines = checks.compactMap { check -> String? in
            let cite = check.citation
            switch check.verdict {
            case .invalidSource:
                return "- [source_invalide] Le document \(cite.documentId) n'existe pas dans la bibliothèque. Utilise un document_id retourné par search_library."
            case .pageOutOfRange(let title, let maxPage):
                return "- [page_hors_limites] « \(title) » ne compte que \(maxPage) pages ; la page \(cite.page) n'existe pas."
            case .quoteNotFound(let title):
                return "- [citation_non_verifiable] L'extrait « \(cite.quote ?? "") » est introuvable dans « \(title) ». Cite les mots EXACTS du texte (via read_page)."
            case .foundElsewhere(let title, let actualPage):
                return "- [page_erronee] L'extrait cité de « \(title) » se trouve page \(actualPage), pas page \(cite.page). Corrige le numéro de page."
            case .valid, .noTextAvailable:
                return nil
            }
        }
        return """
        [Validation des citations — ÉCHEC] Certaines de tes citations sont \
        fausses. Corrige ta réponse (vérifie avec read_page si besoin) et cite à \
        nouveau, sans t'excuser longuement :
        \(lines.joined(separator: "\n"))
        """
    }

    /// Rend le texte lisible : chaque marqueur devient « Titre », p. N.
    public static func rendered(text: String, checks: [Check]) -> String {
        var result = text
        for check in checks {
            result = result.replacingOccurrences(
                of: check.citation.raw,
                with: "(« \(check.title) », p. \(check.citation.page))")
        }
        return result
    }
}
