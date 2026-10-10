import Foundation
import GRDB

/// Genre établi sur pièces ; l'absence de texte n'est pas un genre.
public enum BibliographicKind: String, Codable, Sendable, CaseIterable {
    case livre, article, manuscrit
}

/// Informations de lecture propres à un exemplaire, distinctes de sa notice.
public struct DocumentPresentation: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "document_presentation"
    public var documentId: UUID
    public var kind: BibliographicKind?
    public var label: String?
    public var note: String?
    public var preferred: Bool

    public init(documentId: UUID, kind: BibliographicKind? = nil, label: String? = nil,
                note: String? = nil, preferred: Bool = false) {
        self.documentId = documentId
        self.kind = kind
        self.label = label
        self.note = note
        self.preferred = preferred
    }
}

extension CatalogStore {
    /// Le choix éditorial s'applique à cet exemplaire ; aucun fichier n'est déplacé.
    public func setPresentation(_ value: DocumentPresentation) async throws {
        try await db.pool.write { conn in
            guard try Document.fetchOne(conn, key: value.documentId) != nil else {
                throw DatabaseError(message: "Exemplaire introuvable.")
            }
            try value.save(conn)
        }
    }

    /// Une correction partielle conserve les autres choix de lecture déjà établis.
    public func updatePresentation(documentId: UUID, kind: BibliographicKind? = nil,
                                   label: String? = nil, note: String? = nil, preferred: Bool? = nil) async throws {
        try await db.pool.write { conn in
            guard try Document.fetchOne(conn, key: documentId) != nil else {
                throw DatabaseError(message: "Exemplaire introuvable.")
            }
            var value = try DocumentPresentation.fetchOne(conn, key: documentId) ?? DocumentPresentation(documentId: documentId)
            if let kind { value.kind = kind }
            if let label { value.label = label.isEmpty ? nil : label }
            if let note { value.note = note.isEmpty ? nil : note }
            if let preferred { value.preferred = preferred }
            try value.save(conn)
        }
    }

    /// Responsables de l'édition, sans les confondre avec les auteurs des textes.
    public func setEditionCreators(_ names: [String], role: CreatorRole, editionId: UUID) async throws {
        guard role != .author else { throw DatabaseError(message: "Les auteurs appartiennent à l'œuvre.") }
        try await db.pool.write { conn in
            try EditionCreator.filter(Column("editionId") == editionId && Column("role") == role.rawValue).deleteAll(conn)
            for (position, name) in names.enumerated() {
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let creator: Creator
                if let found = try Creator.filter(Column("name") == name).fetchOne(conn) { creator = found }
                else { creator = Creator(name: name); try creator.insert(conn) }
                try EditionCreator(editionId: editionId, creatorId: creator.id, role: role, position: position).insert(conn)
            }
        }
    }
}
