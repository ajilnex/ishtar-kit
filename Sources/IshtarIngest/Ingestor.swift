import Foundation
import GRDB
import IshtarCatalog

/// Résultat d'une ingestion : ce qui a été créé dans le catalogue, et le bilan chiffré.
public struct IngestReport: Sendable {
    public var total = 0
    public var recognized = 0
    public var needsReview = 0
    public var duplicates = 0
    public var unsupported = 0
    public var collectionsCreated = 0
}

/// Transforme un rapport de scan en enregistrements du catalogue.
///
/// Étage mécanique de l'entonnoir uniquement : nom de fichier pour l'instant,
/// métadonnées embarquées puis catalogues publics aux jalons suivants.
/// L'arborescence de dossiers devient des collections éditables (décision produit).
public struct Ingestor: Sendable {
    public init() {}

    public func ingest(report: ScanReport, sourceFolder: URL, into db: CatalogDatabase) throws -> IngestReport {
        var result = IngestReport()
        result.total = report.files.count
        result.unsupported = report.unsupportedCount

        let duplicatePaths: Set<String> = Set(
            report.duplicateGroups.flatMap { $0.dropFirst().map(\.path) }
        )

        try db.pool.write { dbConn in
            try SourceFolder(path: sourceFolder.standardizedFileURL.path)
                .insert(dbConn, onConflict: .ignore)

            var collectionsByFolder: [String: BookCollection] = [:]

            for file in report.files {
                let guess = FilenameParser.parse(fileName: file.fileName)
                let isDuplicate = duplicatePaths.contains(file.path)

                let status: CurationStatus
                let confidence: Confidence
                switch (isDuplicate, guess.confidence) {
                case (true, _):
                    status = .duplicateCandidate
                    confidence = .low
                    result.duplicates += 1
                case (false, .structured):
                    status = .recognized
                    confidence = .probable
                    result.recognized += 1
                case (false, .fallback):
                    status = .needsReview
                    confidence = .low
                    result.needsReview += 1
                }

                let work = Work(
                    title: guess.title,
                    curationStatus: status,
                    confidence: confidence
                )
                try work.insert(dbConn)

                if let authorName = guess.author {
                    let creator = try Self.findOrCreateCreator(named: authorName, in: dbConn)
                    try WorkCreator(workId: work.id, creatorId: creator.id).insert(dbConn, onConflict: .ignore)
                }

                let edition = Edition(
                    workId: work.id,
                    year: guess.year,
                    isbn13: guess.isbn13,
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
