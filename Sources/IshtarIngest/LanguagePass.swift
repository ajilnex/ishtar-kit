import Foundation
import GRDB
import IshtarCatalog
import NaturalLanguage

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
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= threshold else { return nil }
        return (best.key.rawValue, best.value)
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
