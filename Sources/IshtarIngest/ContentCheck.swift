import Foundation
import GRDB
import IshtarCatalog

/// Ce que le livre lui-même dit de sa fiche.
public struct ContentFinding: Sendable {
    public enum Kind: String, Sendable {
        /// Ni l'auteur ni l'essentiel du titre dans les premières pages.
        case foreign
        /// Le numéro de tome des premières pages n'est pas celui de la fiche.
        case volumeMismatch
    }
    public let kind: Kind
    public let workId: UUID
    public let documentId: UUID
    public let fileName: String
    public let title: String
    public let author: String?
    public let pageCount: Int
    /// Les premières lignes du livre, pour qui doit trancher.
    public let opening: String
}

/// Deux fichiers d'éditions différentes qui sont le même livre : même nombre
/// de pages, même ouverture (« Wilfrid-Sellars-on-Truth.pdf » était *Fusing
/// the Images*).
public struct ContentTwins: Sendable {
    public let documentIds: [UUID]
    public let editionIds: [UUID]
    public let titles: [String]
    public let paths: [String]
    /// L'indice de la fiche que le texte confirme le mieux (vérifiée d'abord,
    /// puis auteur trouvé et part du titre présente dans l'ouverture).
    public let best: Int
}

/// Le livre comme témoin : les noms de fichiers hérités d'anciens renommages
/// automatiques peuvent mentir (« Wyss 2017 — Hegel Aesthetics » est la
/// *Phénoménologie de l'esprit* ; « Peirce 2021 — Logic of the Future vol. 1 »
/// est le volume 2). On confronte la fiche aux premières pages du texte
/// extrait. Local, sans réseau ; les fiches vérifiées (confiance haute) sont
/// laissées de côté.
public enum ContentCheck {
    /// Pages lues : la couverture, le titre, la page de copyright, l'ours.
    static let openingPages = 1...8

    /// Part des mots significatifs du titre présents dans le texte (pur).
    static func coverage(title: String, in text: String) -> Double {
        let words = IdRefConnector.nameTokens(title).filter { $0.count >= 4 }
        guard !words.isEmpty else { return 1 }
        let haystack = TypographyRestorer.skeleton(text)
        return Double(words.filter { haystack.contains($0) }.count) / Double(words.count)
    }

    public static func examine(in db: CatalogDatabase) async throws -> (findings: [ContentFinding], twins: [ContentTwins]) {
        let rows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT d.id AS documentId, d.filePath AS path, e.id AS editionId, w.id AS workId,
                       COALESCE(NULLIF(e.title, ''), w.title) AS title, w.confidence AS confidence,
                       (SELECT c.name FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                         WHERE wc.workId = w.id AND wc.role = 'author' ORDER BY wc.position LIMIT 1) AS author,
                       (SELECT count(*) FROM document_page p WHERE p.documentId = d.id) AS pages,
                       (SELECT group_concat(content, ' ') FROM (SELECT content FROM document_page p
                          WHERE p.documentId = d.id AND p.pageNumber BETWEEN \(openingPages.lowerBound) AND \(openingPages.upperBound)
                          ORDER BY p.pageNumber)) AS opening,
                       (SELECT group_concat(content, ' ') FROM (SELECT content FROM document_page p
                          WHERE p.documentId = d.id AND p.pageNumber BETWEEN 5 AND 12 ORDER BY p.pageNumber)) AS body
                FROM document d JOIN edition e ON e.id = d.editionId JOIN work w ON w.id = e.workId
                WHERE d.isMissing = 0
                """)
        }
        var findings: [ContentFinding] = []
        var twinsByOpening: [String: [Row]] = [:]
        for row in rows {
            guard let opening: String = row["opening"], opening.count >= 200 else { continue }
            let pages: Int = row["pages"]
            // Jumeaux : même nombre de pages et même texte des pages 5 à 12 (les
            // toutes premières sont souvent des pages d'éditeur communes à une
            // collection, ou vides).
            if let body: String = row["body"] {
                let skeleton = TypographyRestorer.skeleton(body)
                if skeleton.count >= 600 { twinsByOpening["\(pages)|" + String(skeleton.prefix(1500)), default: []].append(row) }
            }

            guard (row["confidence"] as String) != "high" else { continue }
            let title: String = row["title"]
            let author: String? = row["author"]
            let haystack = TypographyRestorer.skeleton(opening)
            let family = Reidentification.family(author)
            let authorFound = family.count >= 3 && haystack.contains(family)
            let covered = coverage(title: title, in: opening)
            let excerpt = String(opening.split(whereSeparator: \.isNewline).joined(separator: " ¦ ").prefix(600))
            let make = { (kind: ContentFinding.Kind) in
                ContentFinding(kind: kind, workId: row["workId"], documentId: row["documentId"],
                               fileName: ((row["path"] as String) as NSString).lastPathComponent,
                               title: title, author: author, pageCount: pages, opening: excerpt)
            }
            if let claimed = EditionGrouping.volumeNumber(title),
               let found = EditionGrouping.volumeNumber(opening, markers: ["tome", "vol", "volume", "band"]), claimed != found {
                findings.append(make(.volumeMismatch))
            } else if !authorFound && covered < 0.5 {
                findings.append(make(.foreign))
            }
        }
        let twins = twinsByOpening.values.filter { Set($0.map { $0["editionId"] as UUID }).count > 1 }.map { rows in
            let scores = rows.map { row -> Double in
                let opening: String = row["opening"] ?? ""
                let family = Reidentification.family(row["author"] as String?)
                let found = family.count >= 3 && TypographyRestorer.skeleton(opening).contains(family)
                return ((row["confidence"] as String) == "high" ? 10 : 0) + (found ? 1 : 0) + coverage(title: row["title"], in: opening)
            }
            let best = scores.indices.max { scores[$0] < scores[$1] } ?? 0
            return ContentTwins(documentIds: rows.map { $0["documentId"] }, editionIds: rows.map { $0["editionId"] },
                                titles: rows.map { $0["title"] }, paths: rows.map { $0["path"] }, best: best)
        }
        return (findings, twins)
    }

    /// Réunit chaque groupe de jumeaux : les fichiers rejoignent l'édition de
    /// la fiche retenue ; les éditions et œuvres vidées disparaissent. Rend le
    /// nombre d'éditions absorbées.
    @discardableResult
    public static func merge(_ twins: [ContentTwins], in db: CatalogDatabase) async throws -> Int {
        var n = 0
        for t in twins {
            let kept = t.editionIds[t.best]
            let absorbed = Array(Set(t.editionIds.filter { $0 != kept }))
            n += try await EditionGrouping.absorb(absorbed, into: kept, in: db)
        }
        return n
    }
}
