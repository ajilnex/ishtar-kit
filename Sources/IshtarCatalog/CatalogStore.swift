import Foundation
import GRDB

/// Une correction de fiche saisie par l'utilisateur.
public struct RecordEdit: Sendable, Equatable {
    public var title: String
    public var authors: [String]
    public var year: String?
    public var publisher: String?
    public var language: String?
    public var isbn13: String?

    public init(
        title: String,
        authors: [String] = [],
        year: String? = nil,
        publisher: String? = nil,
        language: String? = nil,
        isbn13: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.year = year
        self.publisher = publisher
        self.language = language
        self.isbn13 = isbn13
    }
}

/// Écritures de curation dans le catalogue.
///
/// Principe : quand l'humain a corrigé une fiche, Ishtar *sait* —
/// statut `recognized`, confiance `high`. C'est le seul chemin vers `high` :
/// aucune machine ne s'attribue cette confiance.
public struct CatalogStore: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    /// Applique une correction humaine à l'œuvre, son édition et son document.
    public func applyUserEdit(workId: UUID, editionId: UUID?, documentId: UUID, edit: RecordEdit) async throws {
        let cleanTitle = edit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw DatabaseError(message: "Le titre ne peut pas être vide.")
        }

        try await db.pool.write { conn in
            guard var work = try Work.fetchOne(conn, key: workId) else {
                throw DatabaseError(message: "Œuvre introuvable.")
            }
            work.title = cleanTitle
            work.curationStatus = .recognized
            work.confidence = .high
            try work.update(conn)

            // Auteurs : remplacement complet de l'attribution.
            try WorkCreator
                .filter(Column("workId") == workId && Column("role") == CreatorRole.author.rawValue)
                .deleteAll(conn)
            for (position, name) in edit.authors.enumerated() {
                let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanName.isEmpty else { continue }
                let creator: Creator
                if let existing = try Creator.filter(Column("name") == cleanName).fetchOne(conn) {
                    creator = existing
                } else {
                    creator = Creator(name: cleanName)
                    try creator.insert(conn)
                }
                try WorkCreator(workId: workId, creatorId: creator.id, role: .author, position: position)
                    .insert(conn, onConflict: .ignore)
            }
            // Ramasse-miettes : créateurs qui n'attribuent plus rien.
            try conn.execute(sql: """
                DELETE FROM creator WHERE id NOT IN (SELECT creatorId FROM work_creator)
                    AND id NOT IN (SELECT creatorId FROM edition_creator)
                """)

            if let editionId, var edition = try Edition.fetchOne(conn, key: editionId) {
                edition.year = normalized(edit.year)
                edition.publisher = normalized(edit.publisher)
                edition.language = normalized(edit.language)
                edition.isbn13 = normalized(edit.isbn13)
                edition.curationStatus = .recognized
                edition.confidence = .high
                try edition.update(conn)
            }

            if var document = try Document.fetchOne(conn, key: documentId) {
                document.curationStatus = .recognized
                document.confidence = .high
                try document.update(conn)
            }
        }
    }

    /// Change le statut de curation (par ex. « Ignorer », « Marquer reconnu »)
    /// sur le document et son œuvre, sans toucher aux métadonnées.
    public func setStatus(_ status: CurationStatus, documentId: UUID) async throws {
        try await db.pool.write { conn in
            guard var document = try Document.fetchOne(conn, key: documentId) else { return }
            document.curationStatus = status
            if status == .recognized { document.confidence = .high }
            try document.update(conn)

            if let editionId = document.editionId,
               var edition = try Edition.fetchOne(conn, key: editionId)
            {
                edition.curationStatus = status
                if status == .recognized { edition.confidence = .high }
                try edition.update(conn)

                if var work = try Work.fetchOne(conn, key: edition.workId) {
                    work.curationStatus = status
                    if status == .recognized { work.confidence = .high }
                    try work.update(conn)
                }
            }
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
