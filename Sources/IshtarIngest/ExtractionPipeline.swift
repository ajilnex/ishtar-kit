import Foundation
import GRDB
import IshtarCatalog

/// Pilote l'extraction du texte des documents et alimente l'index plein texte.
///
/// Un seul pipeline par flux (invariant n° 3) : c'est ici que passe toute
/// extraction, jamais deux chemins concurrents.
public struct ExtractionPipeline: Sendable {
    public init() {}

    public enum ExtractionError: Error, LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self { case .unreadable(let path): "Impossible d’extraire le texte : \(path)" }
        }
    }

    /// Extrait le texte d'un document et remplace ses pages en base.
    ///
    /// **Idempotent** : les pages existantes du document sont effacées puis
    /// réinsérées dans une même transaction. Met à jour `isTextExtracted` (et
    /// `needsOCR` pour les scans).
    public func extract(documentId: UUID, into db: CatalogDatabase) async throws {
        try Task.checkCancellation()
        // L'extraction (lecture disque, PDFKit, XML) se fait hors transaction.
        guard let document = try await db.pool.read({ try Document.fetchOne($0, key: documentId) }) else {
            return
        }
        guard !document.isMissing, document.format.isTextExtractable else { return }
        guard FileManager.default.isReadableFile(atPath: document.filePath),
              let extracted = TextExtractor.extract(
            fileURL: URL(fileURLWithPath: document.filePath),
            format: document.format
        ) else { throw ExtractionError.unreadable(document.filePath) }
        try Task.checkCancellation()

        try await db.pool.write { conn in
            try Task.checkCancellation()
            guard var fresh = try Document.fetchOne(conn, key: documentId),
                  !fresh.isMissing, fresh.contentHash == document.contentHash else { return }
            // Une lecture sans résultat ne détruit jamais une extraction précédente.
            if extracted.pages.isEmpty,
               try DocumentPage.filter(Column("documentId") == documentId).fetchCount(conn) > 0 {
                fresh.needsOCR = extracted.needsOCR
                try fresh.update(conn)
                return
            }
            // Idempotence : on repart d'une table de pages nette pour ce document.
            try DocumentPage.filter(Column("documentId") == documentId).deleteAll(conn)

            for page in extracted.pages {
                    try DocumentPage(documentId: documentId, pageNumber: page.number, content: page.content)
                        .insert(conn)
            }
            fresh.isTextExtracted = true
            fresh.needsOCR = extracted.needsOCR
            try fresh.update(conn)
        }
    }

    /// Extrait tous les documents en attente (`isTextExtracted == false`) dont le
    /// format est extractible, séquentiellement. Une erreur sur un document ne
    /// bloque jamais les autres (attrapée, journalisée, on continue).
    ///
    /// - Parameter progress: callback `(fait, total)` après chaque document.
    /// - Returns: le nombre de documents extraits sans erreur.
    @discardableResult
    public func extractAllPending(
        into db: CatalogDatabase,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int {
        // La liste vient du format lui-même : ajouter un format au moteur
        // l'inscrit ici sans qu'on ait à y penser (un seul pipeline, invariant n° 3).
        let extractableFormats: Set<String> = Set(
            DocumentFormat.allCases.filter(\.isTextExtractable).map(\.rawValue)
        )

        let pending: [UUID] = try await db.pool.read { conn in
            try Document
                .filter(Column("isTextExtracted") == false)
                .filter(Column("isMissing") == false)
                .filter(extractableFormats.contains(Column("format")))
                .order(Column("originalFileName"))
                .fetchAll(conn)
                .map(\.id)
        }

        let total = pending.count
        var done = 0
        var succeeded = 0
        for id in pending {
            try Task.checkCancellation()
            do {
                try await extract(documentId: id, into: db)
                succeeded += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Log discret sur stderr : un document fautif ne doit pas
                // interrompre le lot.
                FileHandle.standardError.write(Data("Extraction échouée (\(id)) : \(error)\n".utf8))
            }
            done += 1
            progress?(done, total)
        }
        return succeeded
    }
}
