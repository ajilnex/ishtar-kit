import Foundation
import GRDB

/// File Rayons, traitée dans une transaction (T-037, notes et surlignements).
public struct AnnotationImport: Sendable {
    public struct Snapshot: Codable, Equatable, Sendable {
        public var id: String
        public var sha256: String
        public var sorte: String?
        public var citation: String
        public var avant: String?
        public var apres: String?
        public var page: Int?
        public var cfi: String?
        public var note: String?
        public var couleur: String?
        public var geometrie: AnnotationGeometry?
        public var auteur: String?
        public var origine: String?
        public var date: String
        public var modifie: String
        // Présence interdite au lot 2, même si le serveur fournit un objet vide.
        public var dessin: JSONValue?
        public var svg: String?
    }

    public struct Operation: Codable, Equatable, Sendable {
        public var seq: Int64
        public var opId: String
        public var op: String
        public var id: String
        public var sha256: String
        public var base: String?
        public var t: String
        public var auteur: String
        public var instantane: Snapshot
        public var fonds: String?
    }

    public struct Batch: Codable, Sendable {
        public var fonds: String
        public var ops: [Operation]
    }

    /// Sert uniquement à conserver et refuser les dessins hors périmètre.
    public indirect enum JSONValue: Codable, Equatable, Sendable {
        case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSONValue].self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case let .bool(v): try c.encode(v)
            case let .number(v): try c.encode(v)
            case let .string(v): try c.encode(v)
            case let .array(v): try c.encode(v)
            case let .object(v): try c.encode(v)
            }
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public var opId: String
        public var seq: Int64
        public var resultat: String
        public var motif: String?
    }
    public struct Report: Codable, Equatable, Sendable {
        public var resultats: [Result]
        public var appliquees: Int { resultats.filter { $0.resultat == "applique" }.count }
        public var deja: Int { resultats.filter { $0.resultat == "deja" }.count }
        public var rejetees: Int { resultats.filter { $0.resultat == "rejete" }.count }
        enum CodingKeys: String, CodingKey { case resultats, appliquees, deja, rejetees }
        public init(resultats: [Result]) { self.resultats = resultats }
        public init(from decoder: Decoder) throws {
            resultats = try decoder.container(keyedBy: CodingKeys.self).decode([Result].self, forKey: .resultats)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(resultats, forKey: .resultats)
            try c.encode(appliquees, forKey: .appliquees)
            try c.encode(deja, forKey: .deja)
            try c.encode(rejetees, forKey: .rejetees)
        }
    }

    private struct Trace: Codable {
        var operation: Operation
        var motif: String?
    }
    public init() {}

    /// Aucun accès aux fichiers des livres. La simulation joue aussi les opérations
    /// dépendantes et la trace, puis annule la transaction entière.
    public func importer(_ batch: Batch, fonds: String, in pool: DatabasePool, appliquer: Bool = false) async throws -> Report {
        guard !fonds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.fondsObligatoire
        }
        return try await pool.writeWithoutTransaction { db in
            var results: [Result] = []
            try db.inTransaction {
                for operation in batch.ops.sorted(by: { $0.seq < $1.seq }) {
                    results.append(try Self.process(operation, batchFonds: batch.fonds, fonds: fonds, db: db))
                }
                return appliquer ? .commit : .rollback
            }
            return Report(resultats: results)
        }
    }

    public enum ImportError: Error { case fondsObligatoire }

    private static func process(_ op: Operation, batchFonds: String, fonds: String, db: Database) throws -> Result {
        func result(_ status: String, _ motif: String? = nil) -> Result {
            Result(opId: op.opId, seq: op.seq, resultat: status, motif: motif)
        }
        // Un lot étranger ne peut ni acquitter ni empoisonner la trace de ce fonds.
        guard batchFonds == fonds, op.fonds == nil || op.fonds == fonds else { return result("rejete", "fonds étranger") }
        guard !op.opId.isEmpty, op.opId.count <= 128, op.seq > 0 else { return result("rejete", "opId ou seq invalide") }
        if let row = try Row.fetchOne(db, sql: "SELECT fonds, result, detail FROM annotation_import WHERE opId = ?", arguments: [op.opId]) {
            guard row["fonds"] as String == fonds else { return result("rejete", "fonds étranger") }
            guard let detail: String = row["detail"],
                  let trace = try? JSONDecoder().decode(Trace.self, from: Data(detail.utf8)), trace.operation == op
            else { return result("rejete", "opId réutilisé") }
            // Un rejet reste rejeté : « déjà » serait acquitté comme importé par Rayons.
            return row["result"] as String == "rejete" ? result("rejete", trace.motif) : result("deja")
        }
        let outcome = try apply(op, db: db)
        let detail = String(decoding: try JSONEncoder().encode(Trace(operation: op, motif: outcome.motif)), as: UTF8.self)
        try db.execute(sql: "INSERT INTO annotation_import (opId, fonds, seq, annotationId, result, detail, appliedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       arguments: [op.opId, fonds, op.seq, UUID(uuidString: op.id), outcome.resultat, detail, Date()])
        return outcome
    }

    private static func apply(_ op: Operation, db: Database) throws -> Result {
        func result(_ status: String, _ motif: String? = nil) -> Result {
            Result(opId: op.opId, seq: op.seq, resultat: status, motif: motif)
        }
        let s = op.instantane
        guard let id = UUID(uuidString: op.id), UUID(uuidString: s.id) == id,
              hash(op.sha256), s.sha256 == op.sha256,
              let time = date(op.t), let created = date(s.date), let modified = date(s.modifie),
              !op.auteur.isEmpty, op.auteur.count <= 320,
              s.auteur == nil || s.auteur == op.auteur,
              ["poser", "modifier", "retirer"].contains(op.op)
        else { return result("rejete", "opération invalide") }
        guard s.sorte == nil || ["note", "surlignement"].contains(s.sorte), s.dessin == nil, s.svg == nil
        else { return result("rejete", "sorte non prise en charge") }
        guard !s.citation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.citation.count <= 2_000,
              (s.avant?.count ?? 0) <= 48, (s.apres?.count ?? 0) <= 48, (s.note?.count ?? 0) <= 20_000,
              s.page == nil || s.page! >= 1, (s.cfi?.count ?? 0) <= 2_000,
              s.origine == nil || ["pdf", "app", "lecteur"].contains(s.origine!),
              s.geometrie == nil || s.geometrie!.isValid,
              created <= modified, modified <= time,
              op.op == "retirer" || modified == time
        else { return result("rejete", "instantané invalide") }
        let documents = try Document.filter(Column("contentHash") == op.sha256).fetchAll(db)
        guard !documents.isEmpty else { return result("rejete", "document absent") }
        guard documents.count == 1 else { return result("rejete", "document ambigu") }
        let document = documents[0]
        // Les UUID sont liés via GRDB (BLOB), jamais via uuidString en SQL.
        let existing = try Annotation.fetchOne(db, key: id)
        if let existing, existing.documentId != document.id { return result("rejete", "id détourné") }
        if let geometry = s.geometrie, geometry.sha256 != op.sha256 {
            guard op.op != "poser", let stored = existing?.geometry,
                  AnnotationGeometry(json: stored) == geometry
            else { return result("rejete", "géométrie étrangère") }
        }
        let readerColor = s.couleur == nil || ["klein", "redon"].contains(s.couleur!)
        let legacyColor = s.couleur?.range(of: #"^[a-z]{1,16}$"#, options: .regularExpression) != nil
        guard readerColor || (legacyColor && op.op != "poser" && existing != nil && s.couleur == existing?.color)
        else { return result("rejete", "couleur non prise en charge") }
        var annotation = Annotation(id: id, documentId: document.id, pageNumber: s.page, cfi: s.cfi,
                                    quote: s.citation, prefix: s.avant, suffix: s.apres, note: s.note, color: s.couleur,
                                    dateCreated: created, dateModified: time, kind: s.sorte == "note" ? "note" : nil,
                                    author: op.auteur, origin: origin(s.origine), geometry: s.geometrie?.json)
        switch op.op {
        case "poser":
            guard op.base == nil else { return result("rejete", "base invalide") }
            guard s.origine == nil || s.origine == "lecteur" else { return result("rejete", "origine invalide") }
            if let existing {
                return same(existing, annotation) ? result("deja") : result("rejete", "id existant")
            }
            // Un retrait importé garde l'UUID réservé, même après disparition de la ligne.
            let traces = try String.fetchAll(db, sql: "SELECT detail FROM annotation_import WHERE annotationId = ? AND result = 'applique'", arguments: [id])
            if traces.contains(where: { detail in
                guard let trace = try? JSONDecoder().decode(Trace.self, from: Data(detail.utf8)) else { return true }
                return trace.operation.op == "retirer"
            }) { return result("rejete", "id retiré") }
            try annotation.insert(db)
        case "modifier", "retirer":
            guard let existing else { return result("rejete", "annotation absente") }
            guard let base = op.base.flatMap(date), milliseconds(existing.dateModified) == milliseconds(base)
            else { return result("rejete", "conflit") }
            guard time > base else { return result("rejete", "date non croissante") }
            guard existing.kind == nil || existing.kind == "note" else { return result("rejete", "sorte non prise en charge") }
            if op.op == "retirer" {
                guard existing.origin != "pdf" else { return result("rejete", "retrait PDF non pris en charge") }
                try existing.delete(db)
            }
            else {
                // Le Projet et la création appartiennent au catalogue, pas au lecteur.
                annotation.projectId = existing.projectId
                annotation.origin = existing.origin
                annotation.dateCreated = existing.dateCreated
                try annotation.update(db)
            }
        default: return result("rejete", "opération invalide")
        }
        return result("applique")
    }

    private static func same(_ a: Annotation, _ b: Annotation) -> Bool {
        var lhs = a, rhs = b
        lhs.dateCreated = Date(timeIntervalSince1970: Double(milliseconds(a.dateCreated)) / 1000)
        rhs.dateCreated = Date(timeIntervalSince1970: Double(milliseconds(b.dateCreated)) / 1000)
        lhs.dateModified = Date(timeIntervalSince1970: Double(milliseconds(a.dateModified)) / 1000)
        rhs.dateModified = Date(timeIntervalSince1970: Double(milliseconds(b.dateModified)) / 1000)
        return lhs == rhs
    }
    private static func milliseconds(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func hash(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func origin(_ s: String?) -> String { s == "pdf" ? "pdf" : s == "app" ? "app" : "reader" }
    private static func date(_ s: String) -> Date? {
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
