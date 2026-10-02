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
        /// Le texte n'est pas extrait : une source utilisable doit remplacer
        /// cette référence avant qu'une réponse soit annoncée comme vérifiée.
        case noTextAvailable(title: String)
        /// Source et page ne suffisent pas à prouver une affirmation.
        case insufficientQuote(title: String)

        public var isVerified: Bool {
            if case .valid = self { return true }
            return false
        }

        public var isFailure: Bool {
            switch self {
            case .valid: false
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
                 .foundElsewhere(let t, _), .noTextAvailable(let t), .insufficientQuote(let t): t
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
        let info: (title: String, pages: [DocumentPage])? = try? await db.pool.read { conn in
            guard let title = try String.fetchOne(conn, sql: """
                SELECT COALESCE(NULLIF(e.title, ''), w.title, d.originalFileName) FROM document d
                LEFT JOIN edition e ON e.id = d.editionId
                LEFT JOIN work w ON w.id = e.workId
                WHERE d.id = ?
                """, arguments: [citation.documentId]) else { return nil }
            let pages = try DocumentPage.filter(Column("documentId") == citation.documentId)
                .order(Column("pageNumber")).fetchAll(conn)
            return (title, pages)
        }
        guard let info else { return .invalidSource }

        // 2. Le texte est-il extrait ? Sinon : invérifiable.
        guard let maxPage = info.pages.last?.pageNumber,
              info.pages.contains(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return .noTextAvailable(title: info.title) }

        // 3. La page est-elle dans les bornes réelles ?
        guard citation.page >= 1, info.pages.contains(where: { $0.pageNumber == citation.page }) else {
            return .pageOutOfRange(title: info.title, maxPage: maxPage)
        }

        // 4. Verbatim (normalisé) sur la page citée, sinon ailleurs dans le
        // document — « trouvé page X » corrige bien mieux que « non trouvé ».
        guard let quote = citation.quote,
              !quote.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .insufficientQuote(title: info.title)
        }
        let needle = Self.normalized(quote)
        guard needle.count >= 8 else { return .insufficientQuote(title: info.title) }
        let pages = info.pages

        if let cited = pages.first(where: { $0.pageNumber == citation.page }),
           PassageLocator.contains(quote, in: cited.content) {
            return .valid(title: info.title)
        }
        if let elsewhere = pages.first(where: { $0.pageNumber != citation.page
            && PassageLocator.contains(quote, in: $0.content) }) {
            return .foundElsewhere(title: info.title, actualPage: elsewhere.pageNumber)
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
            case .noTextAvailable(let title):
                return "- [texte_indisponible] « \(title) » n'a aucun texte vérifiable. Ne présente pas cette citation comme une preuve ; signale la limite ou utilise une autre source."
            case .insufficientQuote(let title):
                return "- [extrait_manquant] Fournis six à douze mots EXACTS de « \(title) », lus avec read_page. Une source et un numéro de page seuls ne prouvent pas la citation."
            case .valid:
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
                with: "(« \(check.title) », p. \(check.citation.page)\(check.verdict.isVerified ? "" : " — non vérifiée"))")
        }
        return result
    }

    /// Ne laisse pas un marqueur mal formé contourner la validation.
    public static func hasUnparsedMarkers(in text: String) -> Bool {
        var remaining = text
        for citation in extract(from: text) {
            remaining = remaining.replacingOccurrences(of: citation.raw, with: "")
        }
        return remaining.contains("[[cite:")
    }
}
