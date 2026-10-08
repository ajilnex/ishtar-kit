import Foundation
import GRDB

/// Une clé retirée — une **pierre tombale** (décision C4 du 03/10/2026). Une clé
/// qui a pu être citée ne disparaît jamais : quand elle se révèle fausse (la
/// fiche corrigée ne dit plus ce qu'elle disait), elle est retirée et renvoie à
/// la clé juste de la même édition. Elle n'est jamais redonnée à une autre.
public struct RetiredKey: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "edition_key_retired"

    public var key: String
    public var editionId: UUID
    /// La clé qui la remplace (nil : l'édition a disparu, par réunion ou suppression).
    public var replacedBy: String?
    public var reason: String
    public var dateRetired: Date

    public init(key: String, editionId: UUID, replacedBy: String?, reason: String, dateRetired: Date = Date()) {
        self.key = key
        self.editionId = editionId
        self.replacedBy = replacedBy
        self.reason = reason
        self.dateRetired = dateRetired
    }
}

/// La vérification **sur pièces** d'un fichier (04/10/2026, demande d'Aubin :
/// « des agents qui regardent directement les premières pages ») : sa fiche a
/// été confrontée à sa page de titre et à son verso, par deux lecteurs
/// indépendants, ou par un humain. Elle vaut pour ces octets-là : si
/// l'empreinte du fichier change, elle ne vaut plus.
public struct Verification: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "verification"

    public var documentId: UUID
    public var contentHash: String
    /// Qui a lu (« Codex + Claude », « Aubin »).
    public var readers: String
    /// Ce que dit la page de titre, recopié.
    public var proof: String
    public var dateVerified: Date

    public init(documentId: UUID, contentHash: String, readers: String, proof: String, dateVerified: Date = Date()) {
        self.documentId = documentId
        self.contentHash = contentHash
        self.readers = readers
        self.proof = proof
        self.dateVerified = dateVerified
    }
}

public enum VerificationError: Error, Equatable, LocalizedError {
    case noFingerprint(UUID)
    case fingerprintMismatch(expected: String, actual: String)
    case noProof

    public var errorDescription: String? {
        switch self {
        case .noFingerprint: return "Le fichier n'a pas d'empreinte : rien à attester."
        case .fingerprintMismatch(let expected, let actual):
            return "Les pages lues ne sont pas celles de ce fichier (empreinte lue \(expected.prefix(12))…, fichier \(actual.prefix(12))…)."
        case .noProof: return "Une vérification sur pièces exige sa preuve (la page de titre recopiée)."
        }
    }
}

extension CatalogStore {
    /// Inscrit la vérification sur pièces d'un fichier et met sa fiche en
    /// confiance haute : plus aucune passe automatique ne la reprend
    /// (règle 9 de 10-ARCHITECTURE, rétablie le 04/10 pour les fiches lues
    /// par deux lecteurs). `expectedHash` : l'empreinte des pages lues, qui
    /// doit être celle du fichier.
    public func recordVerification(documentId: UUID, readers: String, proof: String,
                                   expectedHash: String? = nil, now: Date = Date()) async throws {
        let proof = proof.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proof.isEmpty else { throw VerificationError.noProof }
        try await db.pool.write { conn in
            guard let document = try Document.fetchOne(conn, key: documentId), let hash = document.contentHash, !hash.isEmpty else {
                throw VerificationError.noFingerprint(documentId)
            }
            if let expectedHash, expectedHash.lowercased() != hash.lowercased() {
                throw VerificationError.fingerprintMismatch(expected: expectedHash, actual: hash)
            }
            try Verification(documentId: documentId, contentHash: hash, readers: readers, proof: proof, dateVerified: now).save(conn)
            try conn.execute(sql: "UPDATE document SET confidence = 'high' WHERE id = ?", arguments: [documentId])
            if let editionId = document.editionId {
                try conn.execute(sql: "UPDATE edition SET confidence = 'high' WHERE id = ?", arguments: [editionId])
                try conn.execute(sql: "UPDATE work SET confidence = 'high' WHERE id = (SELECT workId FROM edition WHERE id = ?)",
                                 arguments: [editionId])
            }
        }
    }

    /// Contrôle d'une entrée « sur pièces » avant toute écriture : preuve non vide,
    /// `sha256` donné et égal à l'empreinte du document. Rend la raison du refus, ou nil.
    public func proofRefusal(documentId: UUID, proof: String?, sha256: String?) async throws -> String? {
        if (proof ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "preuve manquante" }
        guard let sha = sha256, !sha.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "sha256 manquant" }
        let actual = try await db.pool.read { try String.fetchOne($0, sql: "SELECT contentHash FROM document WHERE id = ?", arguments: [documentId]) }
        guard actual?.lowercased() == sha.lowercased() else { return "empreinte différente" }
        return nil
    }

    /// Le sous-titre d'une œuvre (complément du titre, RDA), à part du titre.
    public func setSubtitle(_ subtitle: String?, forWork workId: UUID) async throws {
        try await db.pool.write { conn in
            try conn.execute(sql: "UPDATE work SET subtitle = ? WHERE id = ?", arguments: [subtitle, workId])
        }
    }

    /// Le titre propre à une édition (une traduction a le sien), quand elle en
    /// porte un : c'est lui que publie le catalogue, avant celui de l'œuvre.
    public func setEditionTitleIfPresent(_ title: String, forEdition editionId: UUID) async throws {
        try await db.pool.write { conn in
            try conn.execute(sql: "UPDATE edition SET title = ? WHERE id = ? AND title IS NOT NULL AND title <> ''",
                             arguments: [title, editionId])
        }
    }

    /// Retire la vérification d'un fichier : sa fiche a changé sans lecture des pages.
    public func clearVerification(documentId: UUID) async throws {
        try await db.pool.write { conn in
            _ = try Verification.deleteOne(conn, key: documentId)
        }
    }

    /// Les fichiers vérifiés sur pièces, avec l'empreinte des octets lus.
    public func verifiedHashes() async throws -> [UUID: String] {
        try await db.pool.read { conn in
            Dictionary(uniqueKeysWithValues: try Verification.fetchAll(conn).map { ($0.documentId, $0.contentHash) })
        }
    }

    /// Les pierres tombales, par édition (pour la publication : les anciennes
    /// clés d'une édition, qui y mènent encore). Une pierre dont l'édition a
    /// disparu (réunie à une autre, ou remplacée par une fiche propre) suit
    /// `replacedBy`, de pierre en pierre, jusqu'à la clé vivante ; sans clé
    /// vivante au bout, elle n'est rattachée à rien.
    public func retiredKeysByEdition() async throws -> [UUID: [String]] {
        try await db.pool.read { try RetiredKey.byEdition($0) }
    }
}

extension RetiredKey {
    /// Les anciennes clés par édition vivante (voir `retiredKeysByEdition`).
    /// Une pierre dont la clé est aujourd'hui celle d'une édition vivante
    /// n'est jamais rendue : une clé vivante n'est pas une « ancienne clé ».
    public static func byEdition(_ conn: Database) throws -> [UUID: [String]] {
        let vivantes = Set(try UUID.fetchAll(conn, sql: "SELECT id FROM edition"))
        var editionDeCle: [String: UUID] = [:]
        for k in try EditionKey.fetchAll(conn) { editionDeCle[k.key.lowercased()] = k.editionId }
        let pierres = try RetiredKey.order(Column("dateRetired"), Column("key")).fetchAll(conn)
        var pierreDeCle: [String: RetiredKey] = [:]
        for p in pierres { pierreDeCle[p.key.lowercased()] = p }

        func cible(_ pierre: RetiredKey) -> UUID? {
            if vivantes.contains(pierre.editionId) { return pierre.editionId }
            var suivante = pierre.replacedBy
            for _ in 0..<8 {
                guard let cle = suivante?.lowercased() else { return nil }
                if let e = editionDeCle[cle] { return e }
                guard let p = pierreDeCle[cle] else { return nil }
                if vivantes.contains(p.editionId) { return p.editionId }
                suivante = p.replacedBy
            }
            return nil
        }

        var byEdition: [UUID: [String]] = [:]
        for stone in pierres {
            if editionDeCle[stone.key.lowercased()] != nil { continue }
            guard let e = cible(stone) else { continue }
            byEdition[e, default: []].append(stone.key)
        }
        return byEdition
    }
}
