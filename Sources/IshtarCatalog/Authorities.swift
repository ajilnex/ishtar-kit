import Foundation
import GRDB

/// Un lien entre une fiche d'Ishtar (auteur ou œuvre) et la notice d'un
/// référentiel de bibliothèque : IdRef (l'enseignement supérieur français),
/// la BnF, VIAF, ISNI, Wikidata. C'est ce qui fait d'un nom une personne :
/// « Kant », « I. Kant » et « Immanuel Kant » renvoient à la même notice.
///
/// Trois états : `proposed` (trouvé par la machine, à valider), `confirmed`
/// (validé, ou prouvé : un livre possédé figure parmi les documents que le
/// référentiel rattache à la personne), `rejected` (écarté — ne plus le
/// reproposer).
public struct AuthorityLink: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "authority_link"

    public enum EntityType: String, Codable, Sendable, DatabaseValueConvertible {
        case creator, work
    }

    public enum Scheme: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        case idref, bnf, viaf, isni, wikidata

        /// L'adresse publique de la notice.
        public func url(for identifier: String) -> URL? {
            switch self {
            case .idref: URL(string: "https://www.idref.fr/\(identifier)")
            case .bnf: URL(string: "https://catalogue.bnf.fr/\(identifier)")
            case .viaf: URL(string: "https://viaf.org/viaf/\(identifier)")
            case .isni: URL(string: "https://isni.org/isni/\(identifier)")
            case .wikidata: URL(string: "https://www.wikidata.org/wiki/\(identifier)")
            }
        }
    }

    public enum Status: String, Codable, Sendable, DatabaseValueConvertible {
        case proposed, confirmed, rejected
    }

    public var entityType: EntityType
    public var entityId: UUID
    public var scheme: Scheme
    public var identifier: String
    public var label: String?
    public var status: Status
    public var evidence: String?
    public var dateAssigned: Date

    public init(entityType: EntityType, entityId: UUID, scheme: Scheme, identifier: String,
                label: String? = nil, status: Status, evidence: String? = nil, dateAssigned: Date = Date()) {
        self.entityType = entityType
        self.entityId = entityId
        self.scheme = scheme
        self.identifier = identifier
        self.label = label
        self.status = status
        self.evidence = evidence
        self.dateAssigned = dateAssigned
    }
}

extension CatalogStore {
    /// Les liens d'une fiche, confirmés d'abord.
    public func authorityLinks(for type: AuthorityLink.EntityType, id: UUID) async throws -> [AuthorityLink] {
        try await db.pool.read { conn in
            try AuthorityLink
                .filter(Column("entityType") == type && Column("entityId") == id)
                .fetchAll(conn)
                .sorted { ($0.status == .confirmed ? 0 : 1, $0.scheme.rawValue) < ($1.status == .confirmed ? 0 : 1, $1.scheme.rawValue) }
        }
    }

    /// Enregistre des liens. Un lien existant n'est jamais rétrogradé : un
    /// lien confirmé ou écarté (décision prise) reste tel quel ; un lien
    /// proposé peut devenir confirmé. Rend le nombre de liens écrits.
    @discardableResult
    public func record(_ links: [AuthorityLink]) async throws -> Int {
        try await db.pool.write { conn in
            var written = 0
            for link in links {
                let key: [String: (any DatabaseValueConvertible)?] = [
                    "entityType": link.entityType, "entityId": link.entityId,
                    "scheme": link.scheme, "identifier": link.identifier,
                ]
                if let existing = try AuthorityLink.fetchOne(conn, key: key) {
                    guard existing.status == .proposed, link.status == .confirmed else { continue }
                }
                try link.save(conn)
                written += 1
            }
            return written
        }
    }

    /// Décision de l'utilisateur sur un lien : le confirmer ou l'écarter.
    public func setAuthorityStatus(_ status: AuthorityLink.Status, for link: AuthorityLink) async throws {
        try await db.pool.write { conn in
            var updated = link
            updated.status = status
            updated.dateAssigned = Date()
            try updated.save(conn)
        }
    }

    /// Les fiches (du même type) qui partagent une notice confirmée : deux
    /// auteurs « Kant » et « I. Kant » reliés au même IdRef sont une seule
    /// personne. Rend des groupes d'au moins deux identifiants.
    public func sharedAuthorities(type: AuthorityLink.EntityType, scheme: AuthorityLink.Scheme) async throws -> [(identifier: String, entityIds: [UUID])] {
        try await db.pool.read { conn in
            let links = try AuthorityLink
                .filter(Column("entityType") == type && Column("scheme") == scheme && Column("status") == AuthorityLink.Status.confirmed)
                .fetchAll(conn)
            return Dictionary(grouping: links, by: \.identifier)
                .filter { $0.value.count > 1 }
                .map { (identifier: $0.key, entityIds: $0.value.map(\.entityId)) }
                .sorted { $0.identifier < $1.identifier }
        }
    }
}
