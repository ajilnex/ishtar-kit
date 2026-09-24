import Foundation
import GRDB
import IshtarCatalog

/// Un titre rendu à sa graphie par le Sudoc.
public struct TitleRestoration: Sendable {
    public let workId: UUID
    public let current: String
    public let restored: String
}

/// Étage 3 (réseau, geste volontaire) : les titres hérités de noms de fichiers
/// ont perdu accents et apostrophes (« Traite du ciel », « De l ame »,
/// « Aristotles Ethics »). On cherche dans le Sudoc la notice du même livre —
/// même auteur, **même titre une fois accents et ponctuation retirés** — et
/// l'on reprend sa graphie. En français, la graphie du catalogue entière (sa
/// casse est la norme) ; dans les autres langues, seulement les lettres
/// accentuées et les apostrophes, mot à mot, en gardant la casse de la fiche
/// (« Truth and Truthmakers » ne devient pas « Truth and truthmakers »).
/// Jamais un autre titre ; jamais une fiche vérifiée.
public enum TitlePass {
    /// Retire les caractères de non-classement UNIMARC (NSB/NSE) et les
    /// crochets de restitution.
    static func cleaned(_ title: String) -> String {
        title.unicodeScalars.filter { $0.value != 0x98 && $0.value != 0x9C }.map(String.init).joined()
            .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: #"\s*(\.\.\.|…)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// La graphie à reprendre (pur). nil si le Sudoc ne dit pas le même titre
    /// ou n'apporte rien.
    static func restoration(current: String, sudoc: String, french: Bool) -> String? {
        let candidate = cleaned(sudoc)
        // Ponctuation de notice (« ; » entre titres, « : » ajouté seul) : pas
        // une graphie, une convention de catalogage.
        guard !candidate.contains(";") else { return nil }
        let gained = Set(candidate.filter { !$0.isLetter && !$0.isNumber && $0 != " " })
            .subtracting(current.filter { !$0.isLetter && !$0.isNumber && $0 != " " })
        let accentsGained = candidate.unicodeScalars.contains { !$0.isASCII } || candidate.contains("'") || candidate.contains("’")
        if gained == [":"] && !accentsGained { return nil }
        guard TypographyRestorer.skeleton(candidate) == TypographyRestorer.skeleton(current),
              TypographyRestorer.richness(candidate) > TypographyRestorer.richness(current) else { return nil }
        if french {
            // Première lettre en capitale, comme au catalogue.
            return candidate.prefix(1).uppercased() + candidate.dropFirst()
        }
        // Mot à mot : lettres et apostrophes du Sudoc, casse de la fiche.
        let ours = current.split(separator: " ").map(String.init)
        let theirs = candidate.split(separator: " ").map(String.init)
        guard ours.count == theirs.count else { return nil }
        let merged = zip(ours, theirs).map { (o, t) -> String in
            guard TypographyRestorer.skeleton(o) == TypographyRestorer.skeleton(t) else { return o }
            guard let first = o.first else { return t }
            return (first.isUppercase ? t.prefix(1).uppercased() : t.prefix(1).lowercased()) + t.dropFirst()
        }.joined(separator: " ")
        return merged == current ? nil : merged
    }

    public static func proposals(in db: CatalogDatabase, sudoc: SudocConnector = SudocConnector()) async throws -> [TitleRestoration] {
        let rows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT w.id AS id, w.title AS title,
                       (SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                         WHERE wc.workId = w.id AND wc.role = 'author' ORDER BY wc.position LIMIT 1) AS author,
                       (SELECT e.language FROM edition e WHERE e.workId = w.id AND e.language IS NOT NULL LIMIT 1) AS language
                FROM work w
                WHERE w.confidence != 'high'
                  AND EXISTS (SELECT 1 FROM edition e JOIN document d ON d.editionId = e.id WHERE e.workId = w.id AND d.isMissing = 0)
                """)
        }
        var result: [TitleRestoration] = []
        for row in rows {
            let title: String = row["title"]
            guard title.unicodeScalars.allSatisfy(\.isASCII), !title.contains("'"),
                  let author: String = row["author"], !Reidentification.isPlaceholder(author) else { continue }
            let family = Reidentification.family(author)
            guard family.count >= 3 else { continue }
            guard let records = try? await sudoc.search(title: title, author: family, limit: 8) else { continue }
            let french = (row["language"] as String?) == "fr"
            for r in records {
                for candidate in [r.title, r.subtitle.map { "\(r.title) : \($0)" }].compactMap({ $0 }) {
                    if let restored = restoration(current: title, sudoc: candidate, french: french || r.languages.contains("fre")) {
                        result.append(TitleRestoration(workId: row["id"], current: title, restored: restored))
                        break
                    }
                }
                if result.last?.workId == (row["id"] as UUID) { break }
            }
        }
        return result
    }

    @discardableResult
    public static func apply(_ restorations: [TitleRestoration], to db: CatalogDatabase) async throws -> Int {
        let store = CatalogStore(db: db)
        var n = 0
        for r in restorations where try await store.applyTypography(workId: r.workId, title: r.restored, author: nil) { n += 1 }
        return n
    }
}
