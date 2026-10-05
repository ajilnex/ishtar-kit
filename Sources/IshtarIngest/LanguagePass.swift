import Foundation
import GRDB
import IshtarCatalog
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// La langue d'une édition, reconnue sur son texte (local, sans réseau).
public struct LanguageProposal: Sendable, Equatable {
    public let editionId: UUID
    public let title: String
    /// ISO 639-1 : « fr », « en », « de ».
    public let language: String
    public let confidence: Double
}

/// Étage mécanique : la langue des éditions qui n'en ont pas, reconnue par
/// le framework NaturalLanguage d'Apple sur quelques pages du texte extrait
/// (les premières sont souvent des pages de garde ou de copyright, en
/// anglais même pour un livre français : on lit plus loin). Sans texte, le
/// titre seul ne suffit pas — on s'abstient.
public enum LanguagePass {
    /// Seuil sous lequel on ne dit rien.
    static let threshold = 0.85

    /// Langue dominante d'un texte (pur).
    static func recognize(_ text: String) -> (code: String, confidence: Double)? {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= threshold else { return nil }
        return (best.key.rawValue, best.value)
        #else
        return recognizeByFunctionWords(text)
        #endif
    }

    /// Mots-outils les plus fréquents des langues de la bibliothèque.
    static let functionWords: [String: Set<String>] = [
        "fr": ["le", "la", "les", "de", "des", "du", "et", "est", "un", "une", "que", "qui", "dans", "pour", "pas", "ne", "sur", "par", "au", "aux", "ce", "cette", "il", "elle", "nous", "mais", "ou", "donc", "sont", "à", "se", "en", "avec", "plus", "être"],
        "en": ["the", "of", "and", "to", "is", "that", "in", "it", "for", "as", "with", "was", "this", "be", "are", "by", "which", "not", "but", "or", "from", "have", "an", "they", "we"],
        "de": ["der", "die", "das", "und", "ist", "nicht", "zu", "den", "von", "mit", "sich", "des", "auf", "für", "eine", "ein", "dem", "auch", "es", "als", "wird", "sind", "wie", "aus", "aber"],
        "it": ["il", "di", "che", "la", "è", "per", "un", "non", "una", "del", "della", "sono", "si", "gli", "le", "nel", "con", "da", "come", "ma", "anche", "questo", "alla", "dei", "più"],
        "es": ["el", "los", "las", "de", "que", "y", "en", "un", "una", "es", "por", "con", "no", "para", "se", "del", "su", "al", "como", "más", "pero", "sus", "le", "ya", "o"],
        "la": ["et", "est", "in", "non", "ad", "quod", "cum", "sed", "ut", "qui", "quae", "enim", "autem", "esse", "sunt", "vel", "per", "ex", "ab", "etiam", "nam", "atque", "hoc", "quam", "tamen"],
    ]

    /// Reconnaissance portable (l'outil du serveur, sous Linux — WP-34). Un
    /// mot-outil commun à plusieurs langues (« la », « de », « et ») ne dit
    /// rien : seuls comptent ceux qui n'appartiennent qu'à une langue. La
    /// langue retenue doit en porter la part fixée par le même seuil que
    /// NaturalLanguage ; sans assez d'indices, on s'abstient. Pur.
    static func recognizeByFunctionWords(_ text: String) -> (code: String, confidence: Double)? {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        var scores: [String: Int] = [:]
        for word in words {
            let languages = functionWords.filter { $0.value.contains(word) }
            if languages.count == 1, let code = languages.first?.key { scores[code, default: 0] += 1 }
        }
        let total = scores.values.reduce(0, +)
        guard total >= 30, let best = scores.max(by: { $0.value < $1.value }) else { return nil }
        let confidence = Double(best.value) / Double(total)
        return confidence >= threshold ? (best.key, confidence) : nil
    }

    public static func proposals(in db: CatalogDatabase) async throws -> [LanguageProposal] {
        let rows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT e.id AS editionId, COALESCE(e.title, w.title) AS title,
                       (SELECT group_concat(substr(p.content, 1, 1500), ' ')
                          FROM (SELECT content FROM document_page
                                WHERE documentId = (SELECT d.id FROM document d WHERE d.editionId = e.id AND d.isMissing = 0 LIMIT 1)
                                  AND pageNumber BETWEEN 4 AND 14 ORDER BY pageNumber) p) AS sample
                FROM edition e JOIN work w ON w.id = e.workId
                WHERE e.language IS NULL OR e.language = ''
                """)
        }
        return rows.compactMap { row in
            guard let sample: String = row["sample"], sample.count >= 400,
                  let found = recognize(sample) else { return nil }
            return LanguageProposal(editionId: row["editionId"], title: row["title"],
                                    language: found.code, confidence: found.confidence)
        }
    }

    @discardableResult
    public static func apply(_ proposals: [LanguageProposal], to db: CatalogDatabase) async throws -> Int {
        try await db.pool.write { conn in
            for p in proposals {
                try conn.execute(sql: "UPDATE edition SET language = ? WHERE id = ? AND (language IS NULL OR language = '')",
                                 arguments: [p.language, p.editionId])
            }
            return proposals.count
        }
    }
}
