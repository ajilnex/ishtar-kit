#if canImport(PDFKit)
import CoreText
import Foundation
import GRDB
import PDFKit
import Testing
@testable import IshtarCatalog
@testable import IshtarIngest
@testable import IshtarSearch

// Un PDF surligné dans Aperçu puis enregistré à sa place (25/10) : même fiche,
// nouvelle empreinte, et rien d'orphelin. Textes et titres inventés (dépôt public).
@Suite("Fichier réécrit par une autre app — empreinte, annotations, vignette", .serialized)
struct FichierModifieTests {
    private let texte = "Les intuitions sans concepts sont aveugles."

    /// Un PDF d'une page ; avec `mots`, chacun surligné comme le fait Aperçu.
    private func fabriquer(at url: URL, highlighting mots: [String] = []) throws {
        let nu = url.deletingLastPathComponent().appendingPathComponent("couche-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: nu) }
        var media = CGRect(x: 0, y: 0, width: 600, height: 200)
        let pdf = try #require(CGContext(nu as CFURL, mediaBox: &media, nil))
        pdf.beginPDFPage(nil)
        let police = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attribue = CFAttributedStringCreate(nil, texte as CFString, [kCTFontAttributeName: police] as CFDictionary)!
        pdf.textPosition = CGPoint(x: 30, y: 100)
        CTLineDraw(CTLineCreateWithAttributedString(attribue), pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        let document = try #require(PDFDocument(url: nu)), page = try #require(document.page(at: 0))
        for mot in mots {
            let selection = try #require(document.findString(mot, withOptions: .caseInsensitive).first)
            let zone = selection.bounds(for: page)
            let annotation = PDFAnnotation(bounds: zone, forType: .highlight, withProperties: nil)
            annotation.quadrilateralPoints = [
                NSValue(point: CGPoint(x: 0, y: zone.height)), NSValue(point: CGPoint(x: zone.width, y: zone.height)),
                NSValue(point: CGPoint(x: 0, y: 0)), NSValue(point: CGPoint(x: zone.width, y: 0)),
            ]
            page.addAnnotation(annotation)
        }
        try #require(document.write(to: url), "PDF d'essai non écrit")
    }

    private func dossier() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Une bibliothèque d'un seul livre, cataloguée par le scan complet.
    private func bibliotheque() async throws -> (tmp: URL, db: CatalogDatabase, doc: Document) {
        let tmp = try dossier()
        let livres = tmp.appendingPathComponent("livres", isDirectory: true)
        try FileManager.default.createDirectory(at: livres, withIntermediateDirectories: true)
        try fabriquer(at: livres.appendingPathComponent("Auteur — Essai inventé (2026).pdf"))
        let db = try CatalogDatabase(inMemory: ())
        _ = try Ingestor().ingest(report: LibraryScanner().scan(directory: livres), sourceFolder: livres, into: db)
        let doc = try #require(try await db.pool.read { try Document.fetchOne($0) })
        return (tmp, db, doc)
    }

    private func anciennes(_ db: CatalogDatabase) async throws -> [String] {
        try await db.pool.read { try String.fetchAll($0, sql: "SELECT hash FROM document_former_hash") }
    }

    @Test("Scan complet : même fiche, nouvelle empreinte, l'ancienne gardée ; la suite importe et déplace la vignette")
    func scanComplet() async throws {
        let (tmp, db, avant) = try await bibliotheque(); defer { try? FileManager.default.removeItem(at: tmp) }
        let vignettes = tmp.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: vignettes, withIntermediateDirectories: true)
        let ancienne = try #require(avant.contentHash)
        try Data("png".utf8).write(to: vignettes.appendingPathComponent("\(ancienne).png"))

        try fabriquer(at: URL(fileURLWithPath: avant.filePath), highlighting: ["intuitions"])
        let livres = URL(fileURLWithPath: avant.filePath).deletingLastPathComponent()
        let rapport = try Ingestor().ingest(report: LibraryScanner().scan(directory: livres), sourceFolder: livres, into: db)
        #expect(rapport.added == 0 && rapport.modified.count == 1)
        let apres = try #require(try await db.pool.read { try Document.fetchOne($0, key: avant.id) })
        let nouvelle = try #require(apres.contentHash)
        #expect(nouvelle != ancienne && !apres.isTextExtracted && apres.editionId == avant.editionId)
        #expect(try await anciennes(db) == [ancienne])
        #expect(rapport.modified.first == ModifiedDocument(documentId: avant.id, path: avant.filePath, format: .pdf,
                                                           formerHash: ancienne, contentHash: nouvelle))

        let suite = try await ModifiedDocumentFollowUp.apply(rapport.modified, db: db, thumbnails: vignettes)
        #expect(suite.importedAnnotations == 1 && suite.thumbnailsMoved == 1)
        #expect(!FileManager.default.fileExists(atPath: vignettes.appendingPathComponent("\(ancienne).png").path))
        #expect(FileManager.default.fileExists(atPath: vignettes.appendingPathComponent("\(nouvelle).png").path))
        let notes = try await AnnotationStore(db: db).annotations(documentId: avant.id)
        let note = try #require(notes.first)
        #expect(notes.count == 1 && note.origin == "pdf")
        #expect(AnnotationGeometry(json: try #require(note.geometry))?.sha256 == nouvelle)

        // Recommencer ne change rien : ni doublon, ni nouvelle empreinte.
        let encore = try Ingestor().ingest(report: LibraryScanner().scan(directory: livres), sourceFolder: livres, into: db)
        #expect(encore.modified.isEmpty)
        let bis = try await ModifiedDocumentFollowUp.apply(rapport.modified, db: db, thumbnails: vignettes)
        #expect(bis.importedAnnotations == 0)
        #expect(try await AnnotationStore(db: db).annotations(documentId: avant.id).count == 1)
    }

    @Test("Rescan ciblé : seul le chemin donné est relu ; inchangé, il est gardé ; inconnu, il est ignoré")
    func rescanCible() async throws {
        let (tmp, db, avant) = try await bibliotheque(); defer { try? FileManager.default.removeItem(at: tmp) }
        let inchange = try Ingestor().refreshModified(paths: [avant.filePath], into: db)
        #expect(inchange.kept == 1 && inchange.modified.isEmpty)
        let inconnu = tmp.appendingPathComponent("ailleurs.pdf")
        try fabriquer(at: inconnu)
        #expect(try Ingestor().refreshModified(paths: [inconnu.path], into: db).scanned == 0)

        try fabriquer(at: URL(fileURLWithPath: avant.filePath), highlighting: ["aveugles"])
        let rapport = try Ingestor().refreshModified(paths: [avant.filePath], into: db)
        #expect(rapport.modified.count == 1 && rapport.modified.first?.documentId == avant.id)
        #expect(try await anciennes(db) == [try #require(avant.contentHash)])
        #expect(try await db.pool.read { try Document.fetchCount($0) } == 1)
    }

    @Test("Deuxième enregistrement : le surlignement déjà importé reçoit la géométrie du fichier courant")
    func geometrieSuitLeFichier() async throws {
        let (tmp, db, avant) = try await bibliotheque(); defer { try? FileManager.default.removeItem(at: tmp) }
        let chemin = URL(fileURLWithPath: avant.filePath)
        try fabriquer(at: chemin, highlighting: ["intuitions"])
        let premier = try Ingestor().refreshModified(paths: [chemin.path], into: db)
        _ = try await ModifiedDocumentFollowUp.apply(premier.modified, db: db, thumbnails: nil)

        try fabriquer(at: chemin, highlighting: ["intuitions", "aveugles"])
        let second = try Ingestor().refreshModified(paths: [chemin.path], into: db)
        let suite = try await ModifiedDocumentFollowUp.apply(second.modified, db: db, thumbnails: nil)
        #expect(suite.importedAnnotations == 1)
        let courante = try #require(second.modified.first?.contentHash)
        let notes = try await AnnotationStore(db: db).annotations(documentId: avant.id)
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { AnnotationGeometry(json: $0.geometry ?? "")?.sha256 == courante })
        #expect(try await anciennes(db).count == 2)
    }

    @Test("Une note posée dans Rayons sur le fichier d'avant s'importe encore (empreinte ancienne)")
    func fileRayonsSurAncienneEmpreinte() async throws {
        let (tmp, db, avant) = try await bibliotheque(); defer { try? FileManager.default.removeItem(at: tmp) }
        let ancienne = try #require(avant.contentHash)
        try fabriquer(at: URL(fileURLWithPath: avant.filePath), highlighting: ["intuitions"])
        _ = try Ingestor().refreshModified(paths: [avant.filePath], into: db)

        let instant = "2026-10-25T10:00:00.000Z"
        let id = UUID()
        let cliche = AnnotationImport.Snapshot(id: id.uuidString, sha256: ancienne, sorte: "note", citation: "sans concepts",
                                               page: 1, note: "Note inventée", date: instant, modifie: instant)
        let op = AnnotationImport.Operation(seq: 1, opId: UUID().uuidString, op: "poser", id: id.uuidString, sha256: ancienne,
                                            base: nil, t: instant, auteur: "donateur@example.org", instantane: cliche)
        let bilan = try await AnnotationImport().importer(.init(fonds: "essai", ops: [op]), fonds: "essai", in: db.pool, appliquer: true)
        #expect(bilan.appliquees == 1, "\(bilan.resultats)")
        let notes = try await AnnotationStore(db: db).annotations(documentId: avant.id)
        #expect(notes.contains { $0.id == id })
    }
}
#endif
