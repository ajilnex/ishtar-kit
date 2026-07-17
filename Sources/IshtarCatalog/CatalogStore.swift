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

    /// WP-02e — Applique une proposition d'un catalogue public VALIDÉE par
    /// l'utilisateur : étage 3 de l'entonnoir → statut « reconnu », confiance
    /// « probable » (jamais haute : elle reste réservée à la correction humaine).
    /// Ne touche jamais un document déjà en confiance haute (protection par
    /// construction). `authors` : noms séparés par « ; » dans `proposal.author`.
    public func applyProposal(workId: UUID, editionId: UUID?, documentId: UUID,
                              title: String, authors: [String], year: String?,
                              publisher: String?, language: String?,
                              isbn13: String?, doi: String?) async throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw DatabaseError(message: "Le titre ne peut pas être vide.")
        }

        try await db.pool.write { conn in
            // Protection : document introuvable ou déjà en main humaine → rien.
            guard let document = try Document.fetchOne(conn, key: documentId),
                  document.confidence != .high
            else { return }

            guard var work = try Work.fetchOne(conn, key: workId) else {
                throw DatabaseError(message: "Œuvre introuvable.")
            }
            work.title = cleanTitle
            work.curationStatus = .recognized
            work.confidence = .probable
            try work.update(conn)

            // Auteurs : remplacement complet de l'attribution.
            try WorkCreator
                .filter(Column("workId") == workId && Column("role") == CreatorRole.author.rawValue)
                .deleteAll(conn)
            for (position, name) in authors.enumerated() {
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
                edition.year = normalized(year)
                edition.publisher = normalized(publisher)
                edition.language = normalized(language)
                edition.isbn13 = normalized(isbn13)
                edition.doi = normalized(doi)
                edition.curationStatus = .recognized
                edition.confidence = .probable
                try edition.update(conn)
            }

            var doc = document
            doc.curationStatus = .recognized
            doc.confidence = .probable
            try doc.update(conn)
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

    /// WP-07 — Fusion d'un groupe de doublons : chaque document donné est
    /// rattaché à l'édition du document conservé, puis les éditions sans
    /// document et les œuvres sans édition sont ramassées. Acte humain :
    /// statut « reconnu », confiance haute, sur tout le groupe. La fiche
    /// conservée (titre, auteurs, édition) n'est jamais modifiée — les
    /// corrections humaines priment. Aucun fichier touché.
    public func merge(duplicates: [UUID], into keptDocumentId: UUID) async throws {
        try await db.pool.write { conn in
            guard let kept = try Document.fetchOne(conn, key: keptDocumentId) else {
                throw DatabaseError(message: "Document conservé introuvable.")
            }
            guard let keptEditionId = kept.editionId else {
                throw DatabaseError(message: "Le document conservé n'a pas d'édition.")
            }

            // Rattachement des copies à l'édition conservée, statut reconnu.
            for id in duplicates where id != keptDocumentId {
                guard var document = try Document.fetchOne(conn, key: id) else { continue }
                document.editionId = keptEditionId
                document.curationStatus = .recognized
                document.confidence = .high
                try document.update(conn)
            }

            // Le conservé, son édition et son œuvre passent aussi en reconnu,
            // sans toucher titre/auteurs/année.
            var keptDocument = kept
            keptDocument.curationStatus = .recognized
            keptDocument.confidence = .high
            try keptDocument.update(conn)

            if var edition = try Edition.fetchOne(conn, key: keptEditionId) {
                edition.curationStatus = .recognized
                edition.confidence = .high
                try edition.update(conn)

                if var work = try Work.fetchOne(conn, key: edition.workId) {
                    work.curationStatus = .recognized
                    work.confidence = .high
                    try work.update(conn)
                }
            }

            // Ramasse-miettes : éditions sans document, œuvres sans édition.
            try conn.execute(sql: """
                DELETE FROM edition WHERE id NOT IN
                    (SELECT DISTINCT editionId FROM document WHERE editionId IS NOT NULL)
                """)
            try conn.execute(sql: """
                DELETE FROM work WHERE id NOT IN (SELECT DISTINCT workId FROM edition)
                """)
        }
    }

    /// WP-07 — Réversibilité : détache une copie en lui redonnant une fiche
    /// à part (œuvre + édition neuves, titre = nom de fichier sans extension,
    /// statut « à identifier », confiance basse). L'utilisateur ré-identifie
    /// ensuite (« Proposer à nouveau », ⌘S).
    public func detach(documentId: UUID) async throws {
        try await db.pool.write { conn in
            guard var document = try Document.fetchOne(conn, key: documentId) else { return }

            let stem = (document.originalFileName as NSString).deletingPathExtension
            let work = Work(title: stem, curationStatus: .needsReview, confidence: .low)
            try work.insert(conn)
            let edition = Edition(workId: work.id, curationStatus: .needsReview, confidence: .low)
            try edition.insert(conn)

            document.editionId = edition.id
            document.curationStatus = .needsReview
            document.confidence = .low
            try document.update(conn)
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
