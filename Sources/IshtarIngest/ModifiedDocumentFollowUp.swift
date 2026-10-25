import Foundation
import IshtarCatalog

/// Ce qui suit l'enregistrement d'un fichier par une autre app (Aperçu, Skim…),
/// une fois sa nouvelle empreinte au catalogue : les annotations que le PDF porte
/// entrent dans Ishtar, et la vignette suit l'empreinte. Ishtar n'écrit jamais
/// dans le fichier : seule l'app choisie par l'utilisateur l'a modifié.
public enum ModifiedDocumentFollowUp {
    public struct Outcome: Sendable, Equatable {
        public var importedAnnotations = 0
        public var thumbnailsMoved = 0
        public init() {}
    }

    /// `thumbnails` : le cache de vignettes de la bibliothèque (`<empreinte>.png`),
    /// hors du dossier source. Une vignette choisie à la main reste celle du livre.
    public static func apply(_ modified: [ModifiedDocument], db: CatalogDatabase,
                             thumbnails: URL?) async throws -> Outcome {
        var outcome = Outcome()
        for item in modified {
            if let thumbnails, let former = item.formerHash, let current = item.contentHash, former != current,
               moveThumbnail(in: thumbnails, from: former, to: current) {
                outcome.thumbnailsMoved += 1
            }
            if item.format == .pdf {
                outcome.importedAnnotations += try await PDFAnnotationImporter()
                    .importAnnotations(fromPDFAt: item.path, documentId: item.documentId, into: db)
            }
        }
        return outcome
    }

    /// Renomme `<ancienne>.png` en `<nouvelle>.png` ; si la nouvelle existe déjà,
    /// l'ancienne (devenue orpheline) part. Vrai si l'ancienne existait.
    static func moveThumbnail(in folder: URL, from former: String, to current: String) -> Bool {
        let fm = FileManager.default
        let old = folder.appendingPathComponent("\(former).png")
        let new = folder.appendingPathComponent("\(current).png")
        guard fm.fileExists(atPath: old.path) else { return false }
        if fm.fileExists(atPath: new.path) {
            try? fm.removeItem(at: old)
        } else {
            try? fm.moveItem(at: old, to: new)
        }
        return true
    }
}
