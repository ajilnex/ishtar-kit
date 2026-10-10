import Foundation
import GRDB
import IshtarCatalog

/// Reconnaît, parmi les surlignements du catalogue, ceux qui viennent d'un PDF
/// (Aperçu, Skim, Adobe… : ils sont dans le fichier), et leur donne leur origine
/// (`origin = "pdf"`) et leur géométrie. Le lecteur en ligne n'a pas à les peindre :
/// pdf.js les peint déjà ; il pose seulement une zone de toucher, et se sert de la
/// géométrie là où le texte seul ne retrouve pas la citation.
///
/// La reconnaissance se fait à la même clé que l'importateur (page + citation
/// repliée), sur le même texte, puisque c'est lui qui relit le fichier. Ce qui ne
/// s'y reconnaît pas (un surlignement fait dans Ishtar) n'est pas touché. Un
/// passage ne change ni `dateModified` ni quoi que ce soit d'autre : seulement
/// `origin` et `geometry`. Idempotent.
public struct AnnotationOrigine: Sendable {
    public struct Bilan: Sendable, Equatable {
        /// Les surlignements du document (sorte « surlignement » ou note, hors dessins).
        public var annotations = 0
        /// Ceux que le fichier reconnaît.
        public var reconnues = 0
        /// Parmi eux, ceux qui reçoivent une géométrie.
        public var avecGeometrie = 0
        /// Ceux dont l'origine ou la géométrie change (ou changerait, sans `appliquer`).
        public var modifiees = 0

        public init() {}

        public static func + (a: Bilan, b: Bilan) -> Bilan {
            var s = Bilan()
            s.annotations = a.annotations + b.annotations
            s.reconnues = a.reconnues + b.reconnues
            s.avecGeometrie = a.avecGeometrie + b.avecGeometrie
            s.modifiees = a.modifiees + b.modifiees
            return s
        }
    }

    public init() {}

    /// Un document : relit le PDF à `path`, reconnaît les annotations de la base,
    /// et (avec `appliquer`) pose origine et géométrie. `sha256` est l'empreinte
    /// du fichier lu, celle que la géométrie porte.
    @discardableResult
    public func reconnaitre(documentId: UUID, sha256: String, pdfAt path: String,
                            in db: CatalogDatabase, appliquer: Bool) async throws -> Bilan
    {
        var bilan = Bilan()
        let stockees = try await AnnotationStore(db: db).annotations(documentId: documentId)
            .filter { $0.kind == nil || $0.kind == "note" }
        bilan.annotations = stockees.count
        guard !stockees.isEmpty else { return bilan }

        // La première lecture d'une clé l'emporte, comme à l'import (le second doublon n'est jamais entré).
        var parCle: [String: PDFAnnotationImporter.Markup] = [:]
        for markup in PDFAnnotationImporter().markups(fromPDFAt: path) where parCle[markup.key] == nil {
            parCle[markup.key] = markup
        }
        guard !parCle.isEmpty else { return bilan }

        var changements: [(id: UUID, origin: String, geometry: String?)] = []
        for annotation in stockees {
            // Une annotation faite dans Ishtar ou dans le lecteur en ligne n'est jamais « du fichier ».
            guard annotation.origin == nil || annotation.origin == "pdf",
                  let markup = parCle[PDFAnnotationImporter.key(page: annotation.pageNumber, quote: annotation.quote)]
            else { continue }
            bilan.reconnues += 1
            let geometrie = markup.geometry(sha256: sha256)?.json
            if geometrie != nil { bilan.avecGeometrie += 1 }
            if annotation.origin != "pdf" || annotation.geometry != geometrie {
                bilan.modifiees += 1
                changements.append((annotation.id, "pdf", geometrie))
            }
        }
        guard appliquer, !changements.isEmpty else { return bilan }
        let aEcrire = changements
        try await db.pool.write { conn in
            for c in aEcrire {
                try conn.execute(sql: "UPDATE annotation SET origin = ?, geometry = ? WHERE id = ?",
                                 arguments: [c.origin, c.geometry, c.id])
            }
        }
        return bilan
    }
}
