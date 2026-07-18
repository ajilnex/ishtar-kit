import Foundation
import GRDB

/// La base de catalogue d'une bibliothèque Ishtar.
///
/// Un fichier SQLite par bibliothèque, stocké hors du dossier source de l'utilisateur
/// (le dossier source est en lecture seule — invariant n° 2).
public final class CatalogDatabase: Sendable {
    public let pool: DatabasePool

    public init(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        pool = try DatabasePool(path: url.path)
        try Self.migrator.migrate(pool)
    }

    /// Base en mémoire, pour les tests.
    public init(inMemory _: Void) throws {
        // DatabasePool exige un fichier ; DatabaseQueue suffirait mais on garde
        // un seul type de connexion. Un fichier temporaire fait l'affaire.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-test-\(UUID().uuidString).sqlite")
        pool = try DatabasePool(path: tmp.path)
        try Self.migrator.migrate(pool)
    }

    /// Les migrations connues de cette version du moteur, dans l'ordre.
    public static var knownMigrationIdentifiers: [String] { migrator.migrations }

    /// Les migrations effectivement appliquées à cette base (manifeste d'archive).
    public func appliedMigrationIdentifiers() async throws -> [String] {
        let applied = try await pool.read { try Self.migrator.appliedIdentifiers($0) }
        return Self.knownMigrationIdentifiers.filter(applied.contains)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_ontologie") { db in
            try db.create(table: "creator") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("sortName", .text)
            }

            try db.create(table: "work") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("originalLanguage", .text)
                t.column("date", .text)
                t.column("discipline", .text)
                t.column("notes", .text)
                t.column("curationStatus", .text).notNull()
                t.column("confidence", .text).notNull()
            }

            try db.create(table: "work_creator") { t in
                t.column("workId", .text).notNull().references("work", onDelete: .cascade)
                t.column("creatorId", .text).notNull().references("creator", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
                t.primaryKey(["workId", "creatorId", "role"])
            }

            try db.create(table: "edition") { t in
                t.column("id", .text).primaryKey()
                t.column("workId", .text).notNull().references("work", onDelete: .cascade)
                t.column("title", .text)
                t.column("publisher", .text)
                t.column("year", .text)
                t.column("language", .text)
                t.column("isbn13", .text)
                t.column("doi", .text)
                t.column("curationStatus", .text).notNull()
                t.column("confidence", .text).notNull()
            }

            try db.create(table: "edition_creator") { t in
                t.column("editionId", .text).notNull().references("edition", onDelete: .cascade)
                t.column("creatorId", .text).notNull().references("creator", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
                t.primaryKey(["editionId", "creatorId", "role"])
            }

            try db.create(table: "document") { t in
                t.column("id", .text).primaryKey()
                t.column("editionId", .text).references("edition", onDelete: .setNull)
                t.column("filePath", .text).notNull().unique()
                t.column("originalFileName", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("contentHash", .text).indexed()
                t.column("format", .text).notNull()
                t.column("dateAdded", .datetime).notNull()
                t.column("needsOCR", .boolean).notNull().defaults(to: false)
                t.column("isTextExtracted", .boolean).notNull().defaults(to: false)
                t.column("curationStatus", .text).notNull()
                t.column("confidence", .text).notNull()
            }

            try db.create(table: "collection") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("parentId", .text).references("collection", onDelete: .cascade)
                t.column("sourceFolderPath", .text)
            }

            try db.create(table: "collection_item") { t in
                t.column("collectionId", .text).notNull().references("collection", onDelete: .cascade)
                t.column("workId", .text).notNull().references("work", onDelete: .cascade)
                t.primaryKey(["collectionId", "workId"])
            }

            try db.create(table: "source_folder") { t in
                t.column("id", .text).primaryKey()
                t.column("path", .text).notNull().unique()
                t.column("dateAdded", .datetime).notNull()
            }
        }

        // Pages extraites + index plein texte FTS5 (WP-03). Additive : après v1.
        migrator.registerMigration("v2_document_pages") { db in
            // Une ligne par « page » de texte extraite d'un document. Le fichier
            // source reste en lecture seule (invariant n° 2) : ces pages vivent
            // dans la base, jamais dans le dossier scanné.
            try db.create(table: "document_page") { t in
                t.column("documentId", .text).notNull()
                    .references("document", onDelete: .cascade)
                t.column("pageNumber", .integer).notNull()
                t.column("content", .text).notNull()
                t.primaryKey(["documentId", "pageNumber"])
            }

            // Index FTS5 synchronisé par déclencheurs GRDB sur le contenu des pages.
            // unicode61 + remove_diacritics 2 : la recherche « Verité » retrouve
            // « vérité » (repli des diacritiques à l'indexation ET à la requête).
            try db.create(virtualTable: "document_page_fts", using: FTS5()) { t in
                t.synchronize(withTable: "document_page")
                t.column("content")
                t.tokenizer = .unicode61(diacritics: .remove)
            }
        }

        // Surlignements persistants de l'utilisateur (M2a). Additive : après v2.
        migrator.registerMigration("v3_annotations") { db in
            // Ancrage PAR LE TEXTE (décision d'Aubin 18/07) : la citation exacte
            // fait foi. La page (PDF) ou le CFI (EPUB) ne sont que des indices de
            // résolution — le surlignement survit au remplacement du fichier.
            try db.create(table: "annotation") { t in
                t.column("id", .text).primaryKey()
                t.column("documentId", .text).notNull()
                    .references("document", onDelete: .cascade)
                    .indexed()
                t.column("pageNumber", .integer)   // PDF / pages extraites ; nil pour EPUB
                t.column("cfi", .text)             // EPUB ; nil pour PDF
                t.column("quote", .text).notNull()
                t.column("prefix", .text)
                t.column("suffix", .text)
                t.column("note", .text)
                t.column("color", .text)
                t.column("projectId", .text)       // couches par Projet (réservé, nil en v1)
                t.column("dateCreated", .datetime).notNull()
                t.column("dateModified", .datetime).notNull()
            }
        }

        // Les migrations suivantes (embeddings, liens, artéfacts,
        // conversations du démon) arrivent avec les jalons M2–M4.

        return migrator
    }
}
