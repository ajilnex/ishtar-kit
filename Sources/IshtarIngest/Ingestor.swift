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
    /// Documents disparus du dossier, retirés du catalogue (toujours 0 désormais, décision I01).
    public var removed = 0
    /// Documents absents du scan, conservés au catalogue et marqués introuvables.
    public var missing = 0
    /// Documents introuvables redevenus accessibles à leur emplacement d'origine.
    public var recovered = 0
    /// Documents renommés ou déplacés, réassociés sans ambiguïté par empreinte.
    public var relocated = 0
    /// Parmi les ajoutés : reconnus / à identifier / doublons.
    public var recognized = 0
    public var needsReview = 0
    public var duplicates = 0
    public var unsupported = 0
    public var collectionsCreated = 0
    /// Indique si le scan était incomplet ou inaccessible (aucun document n'est alors altéré).
    public var isScanIncomplete = false
    public var scanErrorMessage: String? = nil

    public init() {}
}

/// Transforme un rapport de scan en enregistrements du catalogue.
///
/// **Idempotent** : ré-ingérer le même dossier ne crée rien de nouveau.
/// Les documents sont identifiés par leur chemin ; les nouveaux entrent,
/// les introuvables restent au catalogue avec leur travail intellectuel (fiches, surlignements,
/// liens et projets) sous le statut `isMissing = true`.
/// Le renommage et le déplacement non ambigus réassocient l'identité par empreinte SHA-256.
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

        // C3 : un scan incomplet ou inaccessible ne doit causer aucune modification ni perte.
        if !report.isComplete || report.hasScanErrors {
            result.isScanIncomplete = true
            result.scanErrorMessage = report.errorMessage ?? "Scan incomplet ou inaccessible"
            return result
        }

        let rootPath = sourceFolder.standardizedFileURL.path
        let duplicatePaths: Set<String> = Set(
            report.duplicateGroups.flatMap { $0.dropFirst().map(\.path) }
        )

        try db.pool.write { dbConn in
            try SourceFolder(path: rootPath).insert(dbConn, onConflict: .ignore)

            // Documents déjà catalogués pour CE dossier source.
            let existingDocs = try Document.fetchAll(dbConn, sql: """
                SELECT * FROM document
                WHERE filePath = ? OR filePath LIKE ?
                """, arguments: [rootPath, rootPath + "/%"])
            let existingDocsByPath = Dictionary(uniqueKeysWithValues: existingDocs.map { ($0.filePath, $0) })
            let existingPaths = Set(existingDocsByPath.keys)

            let scannedFilesByPath = Dictionary(uniqueKeysWithValues: report.files.map { ($0.path, $0) })
            let scannedPaths = Set(scannedFilesByPath.keys)

            // 1. Documents toujours présents à leur emplacement d'origine
            let continuingPaths = existingPaths.intersection(scannedPaths)
            for path in continuingPaths {
                var doc = existingDocsByPath[path]!
                if doc.isMissing {
                    // Document introuvable redevenu accessible au même endroit
                    doc.isMissing = false
                    try doc.update(dbConn)
                    result.recovered += 1
                } else {
                    result.kept += 1
                }
            }

            // Documents disparus de leur chemin d'origine
            let vanishedDocs = existingDocs.filter { !scannedPaths.contains($0.filePath) }

            // Fichiers scannés non encore connus en base
            let newFiles = report.files.filter { !existingPaths.contains($0.path) }

            // 2. Rapprochement non ambigu par empreinte SHA-256 (C2 & C4)
            var collectionsByFolder: [String: BookCollection] = [:]

            var vanishedByHash: [String: [Document]] = [:]
            for doc in vanishedDocs {
                if let hash = doc.contentHash {
                    vanishedByHash[hash, default: []].append(doc)
                }
            }

            var newByHash: [String: [ScannedFile]] = [:]
            for file in newFiles {
                if let hash = file.contentHash {
                    newByHash[hash, default: []].append(file)
                }
            }

            let continuingHashes = Set(
                existingDocs.filter { continuingPaths.contains($0.filePath) }
                    .compactMap(\.contentHash)
            )

            var reassociatedDocIds: Set<UUID> = []
            var reassociatedFilePaths: Set<String> = []

            for (hash, vDocs) in vanishedByHash {
                guard let nFiles = newByHash[hash] else { continue }
                // Rapprochement STRICTEMENT non ambigu : exactement 1 disparu, 1 nouveau,
                // et aucun conflit avec un fichier actif portant la même empreinte.
                if vDocs.count == 1, nFiles.count == 1, !continuingHashes.contains(hash) {
                    var doc = vDocs[0]
                    let file = nFiles[0]

                    doc.filePath = file.path
                    doc.originalFileName = file.fileName
                    doc.fileSize = file.fileSize
                    doc.format = file.format
                    doc.isMissing = false
                    try doc.update(dbConn)

                    reassociatedDocIds.insert(doc.id)
                    reassociatedFilePaths.insert(file.path)
                    result.relocated += 1

                    // Mise à jour de collection si le dossier relatif a changé
                    if !file.relativeFolder.isEmpty, let editionId = doc.editionId,
                       let edition = try Edition.fetchOne(dbConn, key: editionId) {
                        let collection = try Self.findOrCreateCollectionChain(
                            relativeFolder: file.relativeFolder,
                            cache: &collectionsByFolder,
                            created: &result.collectionsCreated,
                            in: dbConn
                        )
                        try CollectionItem(collectionId: collection.id, workId: edition.workId)
                            .insert(dbConn, onConflict: .ignore)
                    }
                }
            }

            // 3. Documents disparus non réassociés : conservés au catalogue et marqués introuvables (C1)
            for var doc in vanishedDocs where !reassociatedDocIds.contains(doc.id) {
                if !doc.isMissing {
                    doc.isMissing = true
                    try doc.update(dbConn)
                }
                result.missing += 1
            }

            // 4. Nouveaux fichiers non réassociés : insérés dans le catalogue via l'entonnoir
            let trulyNewFiles = newFiles.filter { !reassociatedFilePaths.contains($0.path) }
            for file in trulyNewFiles {
                let guess = Self.mechanicalGuess(
                    fileName: file.fileName,
                    fileURL: URL(fileURLWithPath: file.path),
                    format: file.format
                )

                let isDuplicate = duplicatePaths.contains(file.path)
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
                    dateAdded: Date(),
                    needsOCR: false,
                    isTextExtracted: false,
                    isMissing: false,
                    curationStatus: status,
                    confidence: confidence
                )
                try document.insert(dbConn)
                result.added += 1

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

            // 5. Ramasse-miettes : éditions sans document, œuvres sans édition.
            // Les documents introuvables restant au catalogue, leurs éditions et œuvres sont préservées.
            try dbConn.execute(sql: """
                DELETE FROM edition WHERE id NOT IN
                    (SELECT DISTINCT editionId FROM document WHERE editionId IS NOT NULL)
                """)
            try dbConn.execute(sql: """
                DELETE FROM work WHERE id NOT IN (SELECT DISTINCT workId FROM edition)
                """)

            // 6. Toute édition née de ce scan ressort avec sa clé de citation.
            try EditionKey.assignMissing(dbConn)
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
