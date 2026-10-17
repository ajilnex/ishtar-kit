import Foundation
import GRDB

/// Fusion de deux éditions à clés figées : tout ce que porte l'édition
/// absorbée passe à l'édition gardée, la clé absorbée devient une pierre qui
/// renvoie à la gardée. Les annotations restent attachées à leur document :
/// seul `document.editionId` change. Rien n'est écrit si un seul comptage
/// d'annotations diffère après coup.
public struct EditionFusion: Sendable {
    public struct MovedDocument: Sendable, Equatable {
        public var id: UUID
        public var fileName: String
        public var annotations: Int
    }

    public struct Report: Sendable {
        public var absorbedKey: String
        public var keptKey: String
        public var documents: [MovedDocument] = []
        public var annotationsKept: Int { documents.reduce(0) { $0 + $1.annotations } }
        /// Pierres qui menaient à la clé absorbée (ou orphelines de son édition) et mènent désormais à la gardée.
        public var stonesRedirected = 0
        public var contributorsCarried = 0
        public var demotedPreferred = 0
        /// La clé gardée était provisoire : elle est figée, car une pierre y renvoie.
        public var keptKeyFrozen = false
        public var editionRemoved = true
        public var workRemoved: String?
    }

    public enum Refus: Error, Equatable, LocalizedError {
        case clesIdentiques
        case cleInconnue(String)
        case dejaPierre(String)
        case annotationsPerdues(String)

        public var errorDescription: String? {
            switch self {
            case .clesIdentiques: return "Les deux clés désignent la même édition : rien à fusionner."
            case .cleInconnue(let k): return "Clé inconnue : \(k)."
            case .dejaPierre(let k): return "La clé « \(k) » est déjà une pierre (clé retirée) : on ne fusionne que des clés vivantes."
            case .annotationsPerdues(let d): return "Fusion refusée : une annotation serait perdue (\(d)). Rien n'est écrit."
            }
        }
    }

    public static let raison = "fusionnée"

    /// `appliquer: false` : essai à blanc, la transaction est annulée.
    static func run(_ conn: Database, absorbedKey: String, keptKey: String,
                    preuve: String?, now: Date) throws -> Report {
        func resolve(_ key: String) throws -> EditionKey {
            if let k = try EditionKey.fetchOne(conn, sql: "SELECT * FROM edition_key WHERE key = ? COLLATE NOCASE", arguments: [key]) { return k }
            if try RetiredKey.fetchOne(conn, sql: "SELECT * FROM edition_key_retired WHERE key = ? COLLATE NOCASE", arguments: [key]) != nil {
                throw Refus.dejaPierre(key)
            }
            throw Refus.cleInconnue(key)
        }
        let absorbed = try resolve(absorbedKey)
        let kept = try resolve(keptKey)
        guard absorbed.editionId != kept.editionId else { throw Refus.clesIdentiques }
        guard let absorbedEdition = try Edition.fetchOne(conn, key: absorbed.editionId),
              let keptEdition = try Edition.fetchOne(conn, key: kept.editionId) else { throw Refus.cleInconnue(absorbedKey) }

        var report = Report(absorbedKey: absorbed.key, keptKey: kept.key)

        // Comptes d'annotations avant : par document, et globaux (dessins, liens).
        func perDocument() throws -> [UUID: Int] {
            var out: [UUID: Int] = [:]
            for row in try Row.fetchAll(conn, sql: "SELECT documentId, count(*) AS n FROM annotation GROUP BY documentId") {
                out[row["documentId"]] = row["n"]
            }
            return out
        }
        func globals() throws -> [Int] {
            try ["annotation", "annotation_drawing", "link", "annotation_import"].map {
                (try conn.tableExists($0)) ? try Int.fetchOne(conn, sql: "SELECT count(*) FROM \($0)") ?? 0 : 0
            }
        }
        let before = try perDocument()
        let globalsBefore = try globals()

        let moved = try Document.filter(Column("editionId") == absorbed.editionId).order(Column("originalFileName")).fetchAll(conn)
        report.documents = moved.map { MovedDocument(id: $0.id, fileName: $0.originalFileName, annotations: before[$0.id] ?? 0) }
        let keptDocumentIds = try UUID.fetchAll(conn, sql: "SELECT id FROM document WHERE editionId = ?", arguments: [kept.editionId])

        // Documents : seul le rattachement change ; le préféré de l'édition gardée le reste.
        if !moved.isEmpty {
            let keptHasPreferred = try Int.fetchOne(conn, sql: """
                SELECT count(*) FROM document_presentation p JOIN document d ON d.id = p.documentId
                WHERE d.editionId = ? AND p.preferred = 1
                """, arguments: [kept.editionId]) ?? 0 > 0
            if keptHasPreferred {
                try conn.execute(sql: """
                    UPDATE document_presentation SET preferred = 0
                    WHERE preferred = 1 AND documentId IN (SELECT id FROM document WHERE editionId = ?)
                    """, arguments: [absorbed.editionId])
                report.demotedPreferred = conn.changesCount
            }
            try conn.execute(sql: "UPDATE document SET editionId = ? WHERE editionId = ?",
                             arguments: [kept.editionId, absorbed.editionId])
        }

        // Contributeurs de l'édition, sans doublon.
        let editionContributorsBefore = try Int.fetchOne(conn, sql: "SELECT count(*) FROM edition_creator WHERE editionId = ?", arguments: [kept.editionId]) ?? 0
        try CatalogStore.preserveEditionContributors(from: absorbed.editionId, into: kept.editionId, in: conn)
        let editionContributorsAfter = try Int.fetchOne(conn, sql: "SELECT count(*) FROM edition_creator WHERE editionId = ?", arguments: [kept.editionId]) ?? 0
        report.contributorsCarried = editionContributorsAfter - editionContributorsBefore

        // La clé gardée sert désormais de renvoi : provisoire, elle pourrait être recalculée et la pierre ne mènerait plus nulle part.
        if kept.origin == .generated {
            try conn.execute(sql: "UPDATE edition_key SET origin = ? WHERE editionId = ?", arguments: [EditionKey.Origin.stable, kept.editionId])
            report.keptKeyFrozen = true
        }

        // L'ancienne clé : effacée (le déclencheur laisse une pierre sauf si elle était provisoire), puis pierre « fusionnée ».
        try conn.execute(sql: "DELETE FROM edition_key WHERE editionId = ?", arguments: [absorbed.editionId])
        let reason = Self.raison + ((preuve?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : " : " + $0 } ?? "")
        try conn.execute(sql: """
            INSERT INTO edition_key_retired (key, editionId, replacedBy, reason, dateRetired) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET replacedBy = excluded.replacedBy, reason = excluded.reason
            """, arguments: [absorbed.key, absorbed.editionId, kept.key, reason, now])
        // Pierres en chaîne : celles qui menaient à l'ancienne clé, ou restées sans renvoi sur cette édition, mènent à la gardée.
        try conn.execute(sql: """
            UPDATE edition_key_retired SET replacedBy = ?
            WHERE key <> ? COLLATE NOCASE
              AND (replacedBy = ? COLLATE NOCASE OR (editionId = ? AND replacedBy IS NULL))
            """, arguments: [kept.key, absorbed.key, absorbed.key, absorbed.editionId])
        report.stonesRedirected = conn.changesCount

        // L'édition (vide) et, si elle n'a plus d'édition, son œuvre ; la gardée reçoit leurs notes, collections, liens, auteurs.
        _ = try Edition.deleteOne(conn, key: absorbed.editionId)
        if absorbedEdition.workId != keptEdition.workId,
           try Edition.filter(Column("workId") == absorbedEdition.workId).fetchCount(conn) == 0 {
            try CatalogStore.preserveWorkNotes(from: absorbedEdition.workId, into: keptEdition.workId, in: conn)
            try conn.execute(sql: """
                INSERT OR IGNORE INTO work_creator (workId, creatorId, role, position)
                SELECT ?, creatorId, role,
                       position + COALESCE((SELECT MAX(position) + 1 FROM work_creator WHERE workId = ?), 0)
                FROM work_creator WHERE workId = ? ORDER BY position
                """, arguments: [keptEdition.workId, keptEdition.workId, absorbedEdition.workId])
            report.workRemoved = try Work.fetchOne(conn, key: absorbedEdition.workId)?.title
            _ = try Work.deleteOne(conn, key: absorbedEdition.workId)
        }

        // Garde-fou : aucune annotation ne doit avoir bougé ni disparu.
        let after = try perDocument()
        for (id, n) in before where after[id] != n {
            throw Refus.annotationsPerdues("document \(id.uuidString) : \(n) avant, \(after[id] ?? 0) après")
        }
        if after.count != before.count { throw Refus.annotationsPerdues("comptes par document différents") }
        if try globals() != globalsBefore { throw Refus.annotationsPerdues("annotations, dessins ou liens en nombre différent") }
        let expected = Set(keptDocumentIds).union(moved.map(\.id))
        let there = Set(try UUID.fetchAll(conn, sql: "SELECT id FROM document WHERE editionId = ?", arguments: [kept.editionId]))
        if there != expected { throw Refus.annotationsPerdues("documents de l'édition gardée inattendus") }
        return report
    }
}

extension CatalogStore {
    /// Fusionne l'édition de la clé `absorbedKey` dans celle de `keptKey`. Une seule transaction ;
    /// `apply: false` fait tout puis annule (essai à blanc fidèle, rien n'est écrit).
    @discardableResult
    public func mergeEditions(absorbedKey: String, into keptKey: String, preuve: String? = nil,
                              apply: Bool, now: Date = Date()) async throws -> EditionFusion.Report {
        try await db.pool.write { conn in
            var report: EditionFusion.Report?
            try conn.inSavepoint {
                report = try EditionFusion.run(conn, absorbedKey: absorbedKey, keptKey: keptKey, preuve: preuve, now: now)
                return apply ? .commit : .rollback
            }
            return report!
        }
    }
}
