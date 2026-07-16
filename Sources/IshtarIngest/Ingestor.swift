import Foundation
import GRDB
import IshtarCatalog

/// Bilan d'une ingestion.
public struct IngestReport: Sendable, Equatable {
    /// Documents vus par le scan.
    public var scanned = 0
    /// Nouveaux documents entrés au catalogue.
    public var added = 0
    /// Documents déjà connus, conservés tels quels.
    public var kept = 0
    /// Documents disparus du dossier, retirés du catalogue.
    public var removed = 0
    /// Parmi les ajoutés : reconnus / à identifier / doublons.
    public var recognized = 0
    public var needsReview = 0
    public var duplicates = 0
    public var unsupported = 0
    public var collectionsCreated = 0

    public init() {}
}

/// Transforme un rapport de scan en enregistrements du catalogue.
///
/// **Idempotent** : ré-ingérer le même dossier ne crée rien de nouveau.
/// Les documents sont identifiés par leur chemin ; les nouveaux entrent,
/// les disparus sortent (avec ramasse-miettes des éditions et œuvres orphelines),
/// les connus sont conservés — y compris les corrections faites par l'utilisateur.
///
/// Étage mécanique de l'entonnoir uniquement : nom de fichier pour l'instant,
/// métadonnées embarquées puis catalogues publics aux étapes suivantes de M1.
/// L'arborescence de dossiers devient des collections éditables (décision produit).
public struct Ingestor: Sendable {
    public init() {}

    /// L'entonnoir mécanique (étages 1-2) : nom de fichier puis métadonnées
    /// embarquées. Pur, local, sans réseau, sans écriture.
    public static func mechanicalGuess(fileName: String, fileURL: URL,
                                       format: DocumentFormat) -> MetadataGuess {
        var guess = FilenameParser.parse(fileName: fileName)
        if guess.confidence == .fallback,
           let embedded = EmbeddedMetadata.read(fileURL: fileURL, format: format)
        {
            if embedded.title.isEmpty {
                // Pas de titre embarqué : on garde le titre de repli du nom
                // de fichier, mais on récupère ISBN/DOI/auteur trouvés.
                var merged = embedded
                merged.title = guess.title
                merged.confidence = .fallback
                guess = merged
            } else {
                guess = embedded
            }
        }
        return guess
    }

    /// Rejoue l'entonnoir sur un document déjà catalogué, SANS écrire :
    /// la proposition est retournée à l'appelant, qui décide (WP-01 —
    /// l'ingestion ne réécrit jamais l'existant, ce geste est volontaire).
    /// nil si le document est introuvable.
    public func repropose(documentId: UUID, into db: CatalogDatabase) async throws -> MetadataGuess? {
        guard let doc = try await db.pool.read({ conn in
            try Document.fetchOne(conn, key: documentId)
        }) else { return nil }
        return Self.mechanicalGuess(
            fileName: doc.originalFileName,
            fileURL: URL(fileURLWithPath: doc.filePath),
            format: doc.format
        )
    }

    public func ingest(report: ScanReport, sourceFolder: URL, into db: CatalogDatabase) throws -> IngestReport {
        var result = IngestReport()
        result.scanned = report.files.count
        result.unsupported = report.unsupportedCount

        let rootPath = sourceFolder.standardizedFileURL.path
        let duplicatePaths: Set<String> = Set(
            report.duplicateGroups.flatMap { $0.dropFirst().map(\.path) }
        )

        try db.pool.write { dbConn in
            try SourceFolder(path: rootPath).insert(dbConn, onConflict: .ignore)

            // Documents déjà catalogués pour CE dossier source.
            let existingPaths = Set(try String.fetchAll(dbConn, sql: """
                SELECT filePath FROM document
                WHERE filePath = ? OR filePath LIKE ?
                """, arguments: [rootPath, rootPath + "/%"]))

            let scannedPaths = Set(report.files.map(\.path))

            // 1. Retirer les disparus.
            let vanished = existingPaths.subtracting(scannedPaths)
            if !vanished.isEmpty {
                try Document.filter(vanished.contains(Column("filePath"))).deleteAll(dbConn)
                result.removed = vanished.count
            }

            // 2. Ajouter les nouveaux.
            var collectionsByFolder: [String: BookCollection] = [:]
            for file in report.files {
                if existingPaths.contains(file.path) {
                    result.kept += 1
                    continue
                }

                // Entonnoir : étage 1 (nom de fichier), puis étage 2 (métadonnées
                // embarquées) si le nom n'a rien donné. Local, sans réseau.
                let guess = Self.mechanicalGuess(
                    fileName: file.fileName,
                    fileURL: URL(fileURLWithPath: file.path),
                    format: file.format
                )

                let isDuplicate = duplicatePaths.contains(file.path)
                // Un étage n'emporte la reconnaissance que s'il fournit titre ET auteur.
                let isSolid = guess.confidence == .structured && guess.author != nil

                let status: CurationStatus
                let confidence: Confidence
                switch (isDuplicate, isSolid) {
                case (true, _):
                    status = .duplicateCandidate
                    confidence = .low
                    result.duplicates += 1
                case (false, true):
                    status = .recognized
                    confidence = .probable
                    result.recognized += 1
                case (false, false):
                    status = .needsReview
                    confidence = .low
                    result.needsReview += 1
                }

                let work = Work(title: guess.title, curationStatus: status, confidence: confidence)
                try work.insert(dbConn)

                if let authorName = guess.author {
                    let creator = try Self.findOrCreateCreator(named: authorName, in: dbConn)
                    try WorkCreator(workId: work.id, creatorId: creator.id)
                        .insert(dbConn, onConflict: .ignore)
                }

                let edition = Edition(
                    workId: work.id,
                    publisher: guess.publisher,
                    year: guess.year,
                    language: guess.language,
                    isbn13: guess.isbn13,
                    doi: guess.doi,
                    curationStatus: status,
                    confidence: confidence
                )
                try edition.insert(dbConn)

                let document = Document(
                    editionId: edition.id,
                    filePath: file.path,
                    originalFileName: file.fileName,
                    fileSize: file.fileSize,
                    contentHash: file.contentHash,
                    format: file.format,
                    curationStatus: status,
                    confidence: confidence
                )
                try document.insert(dbConn)
                result.added += 1

                // Dossiers → collections : chaque niveau de l'arborescence source
                // devient une collection, l'œuvre est rattachée au niveau le plus profond.
                if !file.relativeFolder.isEmpty {
                    let collection = try Self.findOrCreateCollectionChain(
                        relativeFolder: file.relativeFolder,
                        cache: &collectionsByFolder,
                        created: &result.collectionsCreated,
                        in: dbConn
                    )
                    try CollectionItem(collectionId: collection.id, workId: work.id)
                        .insert(dbConn, onConflict: .ignore)
                }
            }

            // 3. Ramasse-miettes : éditions sans document, œuvres sans édition.
            try dbConn.execute(sql: """
                DELETE FROM edition WHERE id NOT IN
                    (SELECT DISTINCT editionId FROM document WHERE editionId IS NOT NULL)
                """)
            try dbConn.execute(sql: """
                DELETE FROM work WHERE id NOT IN (SELECT DISTINCT workId FROM edition)
                """)
        }

        return result
    }

    private static func findOrCreateCreator(named name: String, in db: GRDB.Database) throws -> Creator {
        if let existing = try Creator.filter(Column("name") == name).fetchOne(db) {
            return existing
        }
        let creator = Creator(name: name)
        try creator.insert(db)
        return creator
    }

    private static func findOrCreateCollectionChain(
        relativeFolder: String,
        cache: inout [String: BookCollection],
        created: inout Int,
        in db: GRDB.Database
    ) throws -> BookCollection {
        if let cached = cache[relativeFolder] { return cached }

        var parent: BookCollection?
        var pathSoFar = ""
        for component in relativeFolder.split(separator: "/").map(String.init) {
            pathSoFar = pathSoFar.isEmpty ? component : pathSoFar + "/" + component
            if let cached = cache[pathSoFar] {
                parent = cached
                continue
            }
            if let existing = try BookCollection
                .filter(Column("sourceFolderPath") == pathSoFar)
                .fetchOne(db)
            {
                cache[pathSoFar] = existing
                parent = existing
                continue
            }
            let collection = BookCollection(
                name: component,
                parentId: parent?.id,
                sourceFolderPath: pathSoFar
            )
            try collection.insert(db)
            created += 1
            cache[pathSoFar] = collection
            parent = collection
        }

        guard let leaf = parent else {
            throw DatabaseError(message: "Chemin de collection vide : \(relativeFolder)")
        }
        return leaf
    }
}
