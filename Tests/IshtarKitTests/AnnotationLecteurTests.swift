import Testing
import Foundation
import GRDB
@testable import IshtarCatalog
@testable import IshtarIngest
@testable import IshtarSearch
#if canImport(PDFKit)
import PDFKit
#endif

// T-037, lot 1 : ce que le lecteur en ligne lit des annotations d'Ishtar.
// Titres, citations et empreintes inventés (dépôt public).

private let empreinte = String(repeating: "ab", count: 32)

@Suite("Annotations du lecteur — schéma v11, géométrie, publication")
struct AnnotationLecteurTests {
    /// Une base avec un document PDF publié sous `empreinte`.
    private func bibliotheque(hash: String? = empreinte, path: String = "/lib/Essais/livre.pdf") async throws -> (CatalogDatabase, UUID) {
        let db = try CatalogDatabase(inMemory: ())
        let work = Work(title: "Essais inventés")
        let edition = Edition(workId: work.id)
        let document = Document(editionId: edition.id, filePath: path, originalFileName: "livre.pdf",
                                fileSize: 1, contentHash: hash, format: .pdf)
        try await db.pool.write { conn in
            try work.insert(conn)
            try edition.insert(conn)
            try document.insert(conn)
        }
        return (db, document.id)
    }

    // MARK: - Migration

    @Test("La migration v11 ajoute les champs sans rien perdre, et les annotations anciennes restent lisibles")
    func migration() async throws {
        let (db, docId) = try await bibliotheque()
        #expect(CatalogDatabase.knownMigrationIdentifiers.contains("v11_annotations_lecteur"))
        #expect(try await db.appliedMigrationIdentifiers().contains("v11_annotations_lecteur"))
        let colonnes = try await db.pool.read { try Row.fetchAll($0, sql: "PRAGMA table_info(annotation)").map { $0["name"] as String } }
        for c in ["kind", "author", "origin", "geometry"] { #expect(colonnes.contains(c)) }
        let tables = try await db.pool.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        #expect(tables.contains("annotation_drawing") && tables.contains("annotation_import"))

        // Une ligne écrite à la manière d'avant la v11 (sans les nouvelles colonnes) se relit.
        let id = UUID()
        try await db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO annotation (id, documentId, pageNumber, quote, dateCreated, dateModified)
                VALUES (?, ?, 3, 'une citation ancienne', '2026-01-02 03:04:05.000', '2026-01-02 03:04:05.000')
                """, arguments: [id, docId])
        }
        let lues = try await AnnotationStore(db: db).annotations(documentId: docId)
        let relue = try #require(lues.first)
        #expect(relue.id == id && relue.kind == nil && relue.origin == nil && relue.geometry == nil)
    }

    @Test("Une annotation faite dans l'application reçoit l'origine « app » ; celle qui porte déjà une origine la garde")
    func origineParDefaut() async throws {
        let (db, docId) = try await bibliotheque()
        let store = AnnotationStore(db: db)
        let faite = try await store.add(Annotation(documentId: docId, pageNumber: 1, quote: "faite ici"))
        let lue = try await store.add(Annotation(documentId: docId, pageNumber: 1, quote: "lue dans le fichier", origin: "pdf"))
        #expect(faite.origin == "app" && lue.origin == "pdf")
        let rows = try await store.annotations(documentId: docId)
        #expect(Set(rows.compactMap(\.origin)) == ["app", "pdf"])
    }

    // MARK: - Géométrie (pure)

    @Test("Les rectangles se normalisent dans la cropBox, origine en haut à gauche, quatre décimales")
    func normalisation() {
        let crop = CGRect(x: 10, y: 20, width: 200, height: 100)
        // Un rectangle à 40 de la gauche de la cropBox, 10 sous son bord haut, de 50 sur 8.
        let rect = CGRect(x: 50, y: 20 + 100 - 10 - 8, width: 50, height: 8)
        let n = AnnotationGeometry.normalize([rect], in: crop)
        #expect(n == [[0.2, 0.1, 0.25, 0.08]])
        // Hors page, vide ou dégénéré : écarté ; à cheval : borné.
        let sortie = AnnotationGeometry.normalize([
            CGRect(x: 500, y: 500, width: 5, height: 5), CGRect(x: 20, y: 30, width: 0, height: 4),
            CGRect(x: 190, y: 20, width: 40, height: 10),
        ], in: crop)
        #expect(sortie == [[0.9, 0.9, 0.1, 0.1]])
    }

    @Test("Les morceaux d'une même ligne se réunissent ; deux lignes restent deux, de haut en bas")
    func fusionDesLignes() {
        let mots = [
            CGRect(x: 100, y: 500, width: 30, height: 10), CGRect(x: 134, y: 500, width: 30, height: 10),
            CGRect(x: 100, y: 485, width: 25, height: 10),
            CGRect(x: 300, y: 500, width: 20, height: 10),   // trop loin : une autre plage de la ligne
        ]
        let fusion = AnnotationGeometry.mergeLines(mots)
        #expect(fusion.count == 3)
        #expect(fusion[0] == CGRect(x: 100, y: 500, width: 64, height: 10))
        #expect(fusion[1] == CGRect(x: 300, y: 500, width: 20, height: 10))
        #expect(fusion[2] == CGRect(x: 100, y: 485, width: 25, height: 10))
    }

    @Test("La géométrie tient dans ses bornes (64 rectangles, empreinte valide) ou n'est pas")
    func bornes() {
        let crop = CGRect(x: 0, y: 0, width: 600, height: 800)
        let lignes = (0 ..< 70).map { CGRect(x: 50, y: 20 + Double($0) * 11, width: 300, height: 8) }
        #expect(AnnotationGeometry.make(sha256: empreinte, page: 1, rects: lignes, cropBox: crop) == nil)
        #expect(AnnotationGeometry.make(sha256: empreinte, page: 1, rects: Array(lignes.prefix(64)), cropBox: crop)?.pages[0].rects.count == 64)
        #expect(AnnotationGeometry.make(sha256: "abc", page: 1, rects: [lignes[0]], cropBox: crop) == nil)
        #expect(AnnotationGeometry.make(sha256: empreinte, page: 0, rects: [lignes[0]], cropBox: crop) == nil)

        let bonne = AnnotationGeometry(sha256: empreinte, pages: [.init(page: 2, rects: [[0.1, 0.2, 0.3, 0.04]])])
        #expect(AnnotationGeometry(json: bonne.json) == bonne)
        #expect(bonne.json == #"{"pages":[{"page":2,"rects":[[0.1,0.2,0.3,0.04]]}],"sha256":"\#(empreinte)"}"#)
        #expect(AnnotationGeometry(json: "{}") == nil)
        #expect(AnnotationGeometry(json: #"{"pages":[{"page":1,"rects":[[0.1,0.2,1.5,0.1]]}],"sha256":"\#(empreinte)"}"#) == nil)
        #expect(AnnotationGeometry(json: #"{"pages":[{"page":1,"rects":[[0.1,0.2,0.1]]}],"sha256":"\#(empreinte)"}"#) == nil)
        let cinqPages = (1 ... 5).map { AnnotationGeometry.PageRects(page: $0, rects: [[0, 0, 0.5, 0.5]]) }
        #expect(AnnotationGeometry(sha256: empreinte, pages: cinqPages).isValid == false)
    }

    // MARK: - Publication

    private func publiees(_ db: CatalogDatabase) async throws -> [[String: Any]] {
        let json = try await CatalogPublisher.annotationsJSON(db: db, hashes: [empreinte])
        let objet = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        return try #require(objet["annotations"] as? [[String: Any]])
    }

    @Test("annotations.json garde ses champs d'avant et ajoute sorte, auteur, origine, modifie, geometrie")
    func publication() async throws {
        let (db, docId) = try await bibliotheque()
        let geometrie = AnnotationGeometry(sha256: empreinte, pages: [.init(page: 12, rects: [[0.1, 0.2, 0.3, 0.02]])])
        let creee = Date(timeIntervalSince1970: 1_700_000_000)
        let modifiee = Date(timeIntervalSince1970: 1_700_000_123.456)
        let surlignement = Annotation(documentId: docId, pageNumber: 12, quote: "La vie ne vit pas", note: "clé",
                                      dateCreated: creee, dateModified: modifiee, origin: "pdf", geometry: geometrie.json)
        let ancienne = Annotation(documentId: docId, pageNumber: 40, quote: "Sans rien de neuf", dateCreated: creee, dateModified: creee)
        let invalide = Annotation(documentId: docId, pageNumber: 41, quote: "Géométrie hors bornes", dateCreated: creee, dateModified: creee,
                                  origin: "pdf", geometry: #"{"pages":[{"page":41,"rects":[[0,0,9,9]]}],"sha256":"\#(empreinte)"}"#)
        let inconnue = Annotation(documentId: docId, pageNumber: 42, quote: "Une sorte d'un autre âge", dateCreated: creee, dateModified: creee, kind: "hologramme")
        let note = Annotation(documentId: docId, pageNumber: 43, quote: "Une note", dateCreated: creee, dateModified: creee,
                              kind: "note", author: "lectrice@example.org", origin: "reader")
        try await db.pool.write { conn in
            for a in [surlignement, ancienne, invalide, inconnue, note] { try a.insert(conn) }
        }
        let notes = try await publiees(db)
        #expect(notes.map { $0["citation"] as? String } == ["La vie ne vit pas", "Sans rien de neuf", "Géométrie hors bornes", "Une note"],
                "la sorte inconnue ne sort pas")
        let premiere = notes[0]
        #expect(premiere["page"] as? Int == 12 && premiere["note"] as? String == "clé" && premiere["sha256"] as? String == empreinte)
        #expect(premiere["origine"] as? String == "pdf" && premiere["sorte"] == nil && premiere["auteur"] == nil)
        #expect(premiere["date"] as? String == "2023-11-14T22:13:20Z")
        #expect(premiere["modifie"] as? String == "2023-11-14T22:15:23.456Z")
        let g = try #require(premiere["geometrie"] as? [String: Any])
        #expect(g["sha256"] as? String == empreinte)
        let pages = try #require(g["pages"] as? [[String: Any]])
        #expect(pages[0]["page"] as? Int == 12)
        #expect((pages[0]["rects"] as? [[Double]]) == [[0.1, 0.2, 0.3, 0.02]])
        // Une annotation d'avant la v11 : aucun champ d'origine, de géométrie ni de sorte.
        #expect(notes[1]["origine"] == nil && notes[1]["geometrie"] == nil && notes[1]["sorte"] == nil && notes[1]["auteur"] == nil)
        #expect(notes[2]["geometrie"] == nil && notes[2]["origine"] as? String == "pdf", "une géométrie hors bornes ne sort pas")
        #expect(notes[3]["sorte"] as? String == "note" && notes[3]["auteur"] as? String == "lectrice@example.org" && notes[3]["origine"] as? String == "lecteur")
        // Rien ne change : le fichier est identique.
        let premierJet = try await CatalogPublisher.annotationsJSON(db: db, hashes: [empreinte])
        let secondJet = try await CatalogPublisher.annotationsJSON(db: db, hashes: [empreinte])
        #expect(premierJet == secondJet)
    }

    @Test("Un dessin publie ses traits et son SVG ; sa sorte se dit « dessin »")
    func publicationDuDessin() async throws {
        let (db, docId) = try await bibliotheque()
        let a = Annotation(documentId: docId, pageNumber: 3, quote: "Un groupe de mots", kind: "drawing", origin: "reader")
        try await db.pool.write { conn in
            try a.insert(conn)
            try conn.execute(sql: "INSERT INTO annotation_drawing (annotationId, strokes, svg, width, height) VALUES (?, ?, ?, 1000, 1414)",
                             arguments: [a.id, #"[{"c":"encre","e":2.5,"p":[[1,2,0.5,0]]}]"#, #"<svg viewBox="0 0 1000 1414"></svg>"#])
        }
        let toutes = try await publiees(db)
        let n = try #require(toutes.first)
        #expect(n["sorte"] as? String == "dessin")
        let dessin = try #require(n["dessin"] as? [String: Any])
        #expect(dessin["largeur"] as? Double == 1000 && dessin["hauteur"] as? Double == 1414)
        #expect((dessin["traits"] as? [[String: Any]])?.count == 1)
        #expect(n["svg"] as? String == #"<svg viewBox="0 0 1000 1414"></svg>"#)
        // Retirer l'annotation emporte son dessin.
        try await AnnotationStore(db: db).remove(id: a.id)
        let restes = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM annotation_drawing") }
        #expect(restes == 0)
    }
}

// PDFKit : propre à macOS.
#if canImport(PDFKit)
@Suite("Annotations des PDF — origine et géométrie")
struct AnnotationOrigineTests {
    private let texte = "Les intuitions sans concepts sont aveugles."

    /// Un PDF 600 × 200 dont le texte est à (30, 100), avec une cropBox et une rotation
    /// facultatives, puis un surlignement standard sur `mot`. PDFKit ne réécrit pas
    /// fiablement un document en place : on dépose la couche texte à côté, puis la
    /// version annotée à l'emplacement demandé.
    private func fabriquer(at url: URL, highlighting mot: String?, cropBox: CGRect? = nil, rotation: Int = 0) {
        let nu = url.deletingLastPathComponent().appendingPathComponent("couche-\(UUID().uuidString).pdf")
        var media = CGRect(x: 0, y: 0, width: 600, height: 200)
        guard let pdf = CGContext(nu as CFURL, mediaBox: &media, nil) else { return }
        pdf.beginPDFPage(nil)
        let police = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attribue = CFAttributedStringCreate(nil, texte as CFString, [kCTFontAttributeName: police] as CFDictionary)!
        pdf.textPosition = CGPoint(x: 30, y: 100)
        CTLineDraw(CTLineCreateWithAttributedString(attribue), pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        defer { try? FileManager.default.removeItem(at: nu) }

        guard let document = PDFDocument(url: nu), let page = document.page(at: 0) else { return }
        if let cropBox { page.setBounds(cropBox, for: .cropBox) }
        if rotation != 0 { page.rotation = rotation }
        if let mot, let selection = document.findString(mot, withOptions: .caseInsensitive).first {
            let zone = selection.bounds(for: page)
            let annotation = PDFAnnotation(bounds: zone, forType: .highlight, withProperties: nil)
            // Comme Aperçu : une ligne, quatre coins relatifs au cadre de l'annotation.
            annotation.quadrilateralPoints = [
                NSValue(point: CGPoint(x: 0, y: zone.height)), NSValue(point: CGPoint(x: zone.width, y: zone.height)),
                NSValue(point: CGPoint(x: 0, y: 0)), NSValue(point: CGPoint(x: zone.width, y: 0)),
            ]
            page.addAnnotation(annotation)
        }
        document.write(to: url)
    }

    private func dossier() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Où est le mot dans la page, normalisé dans la cropBox (la vérité, mesurée par PDFKit).
    private func attendu(_ mot: String, cropBox: CGRect?, in url: URL) throws -> [Double] {
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let zone = try #require(document.findString(mot, withOptions: .caseInsensitive).first).bounds(for: page)
        let crop = cropBox ?? page.bounds(for: .cropBox)
        return try #require(AnnotationGeometry.normalize([zone], in: crop).first)
    }

    private func proche(_ a: [Double], _ b: [Double], _ tolerance: Double = 0.002) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test("Un surlignement de PDF sort avec l'origine « pdf » et sa géométrie, rectangles dans la cropBox")
    func importAvecGeometrie() async throws {
        let tmp = try dossier(); defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("a.pdf")
        let crop = CGRect(x: 10, y: 10, width: 560, height: 160)
        fabriquer(at: url, highlighting: "intuitions", cropBox: crop)

        let (db, docId) = try await AnnotationLecteurTests().biblio(path: url.path)
        let ajoutees = try await PDFAnnotationImporter().importAnnotations(fromPDFAt: url.path, documentId: docId, into: db)
        #expect(ajoutees == 1)
        let stockees = try await AnnotationStore(db: db).annotations(documentId: docId)
        let a = try #require(stockees.first)
        #expect(a.origin == "pdf" && a.pageNumber == 1)
        let brute = try #require(a.geometry)
        let g = try #require(AnnotationGeometry(json: brute))
        #expect(g.sha256 == empreinte && g.pages.count == 1 && g.pages[0].page == 1 && g.pages[0].rects.count == 1)
        let vrai = try attendu("intuitions", cropBox: crop, in: url)
        #expect(proche(g.pages[0].rects[0], vrai))
        // Dans la page, de gauche à droite et de haut en bas.
        let r = g.pages[0].rects[0]
        #expect(r[0] > 0.03 && r[0] < 0.2 && r[1] > 0.1 && r[1] < 0.6 && r[2] > 0.05 && r[2] < 0.3)
    }

    @Test("La page tournée (/Rotate) donne les mêmes rectangles : la géométrie est celle de la page non tournée")
    func pageTournee() async throws {
        let tmp = try dossier(); defer { try? FileManager.default.removeItem(at: tmp) }
        let droite = tmp.appendingPathComponent("droite.pdf"), tournee = tmp.appendingPathComponent("tournee.pdf")
        fabriquer(at: droite, highlighting: "concepts")
        fabriquer(at: tournee, highlighting: "concepts", rotation: 90)
        let a = try #require(PDFAnnotationImporter().markups(fromPDFAt: droite.path).first)
        let b = try #require(PDFAnnotationImporter().markups(fromPDFAt: tournee.path).first)
        #expect(b.quote.lowercased().contains("concepts"))
        let ga = try #require(a.geometry(sha256: empreinte)), gb = try #require(b.geometry(sha256: empreinte))
        #expect(ga == gb)
        #expect(PDFDocument(url: tournee)?.page(at: 0)?.rotation == 90)
    }

    @Test("annotations-origine : reconnaît par page + citation, ne touche ni les autres ni la date de modification, et recommence sans rien changer")
    func reconnaissance() async throws {
        let tmp = try dossier(); defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("b.pdf")
        fabriquer(at: url, highlighting: "sans concepts")
        let (db, docId) = try await AnnotationLecteurTests().biblio(path: url.path)

        // Importée avant la v11 : ni origine ni géométrie. Une autre est faite dans Ishtar (même page, autre texte).
        let hier = Date(timeIntervalSince1970: 1_700_000_000)
        let lue = try #require(PDFAnnotationImporter().markups(fromPDFAt: url.path).first)
        let ancienne = Annotation(documentId: docId, pageNumber: 1, quote: lue.quote, prefix: lue.prefix, suffix: lue.suffix, dateCreated: hier, dateModified: hier)
        let faiteIci = Annotation(documentId: docId, pageNumber: 1, quote: "aveugles", dateCreated: hier, dateModified: hier, origin: "app")
        let deMemeTexte = Annotation(documentId: docId, pageNumber: 1, quote: lue.quote, dateCreated: hier, dateModified: hier, origin: "app")
        try await db.pool.write { conn in
            try ancienne.insert(conn); try faiteIci.insert(conn); try deMemeTexte.insert(conn)
        }

        let outil = AnnotationOrigine()
        let simulation = try await outil.reconnaitre(documentId: docId, sha256: empreinte, pdfAt: url.path, in: db, appliquer: false)
        #expect(simulation.annotations == 3 && simulation.reconnues == 1 && simulation.avecGeometrie == 1 && simulation.modifiees == 1)
        let intact = try await AnnotationStore(db: db).annotations(documentId: docId)
        #expect(intact.allSatisfy { $0.geometry == nil } && intact.filter { $0.origin == "pdf" }.isEmpty, "sans --appliquer, rien n'est écrit")

        let faite = try await outil.reconnaitre(documentId: docId, sha256: empreinte, pdfAt: url.path, in: db, appliquer: true)
        #expect(faite == simulation)
        let apres = try await db.pool.read { try Annotation.fetchAll($0) }
        let a = try #require(apres.first { $0.id == ancienne.id })
        #expect(a.origin == "pdf" && a.geometry != nil && a.dateModified == hier, "la date de modification ne bouge pas")
        let b = try #require(apres.first { $0.id == faiteIci.id })
        #expect(b.origin == "app" && b.geometry == nil)
        let c = try #require(apres.first { $0.id == deMemeTexte.id })
        #expect(c.origin == "app" && c.geometry == nil, "une annotation d'Ishtar n'est jamais « du fichier »")

        let seconde = try await outil.reconnaitre(documentId: docId, sha256: empreinte, pdfAt: url.path, in: db, appliquer: true)
        #expect(seconde.modifiees == 0 && seconde.reconnues == 1)
        // L'annotation passe dans la publication, avec sa géométrie.
        let json = try await CatalogPublisher.annotationsJSON(db: db, hashes: [empreinte])
        let objet = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let notes = try #require(objet["annotations"] as? [[String: Any]])
        let publiee = try #require(notes.first { $0["id"] as? String == ancienne.id.uuidString })
        #expect(publiee["origine"] as? String == "pdf" && publiee["geometrie"] != nil)
    }

    @Test("Un fichier remplacé (autre empreinte) renouvelle la géométrie ; un fichier absent ne change rien")
    func fichierRemplace() async throws {
        let tmp = try dossier(); defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("c.pdf")
        fabriquer(at: url, highlighting: "aveugles")
        let (db, docId) = try await AnnotationLecteurTests().biblio(path: url.path)
        try await PDFAnnotationImporter().importAnnotations(fromPDFAt: url.path, documentId: docId, into: db)
        let autre = String(repeating: "cd", count: 32)
        let outil = AnnotationOrigine()
        let bilan = try await outil.reconnaitre(documentId: docId, sha256: autre, pdfAt: url.path, in: db, appliquer: true)
        #expect(bilan.modifiees == 1)
        let stockees = try await AnnotationStore(db: db).annotations(documentId: docId)
        let a = try #require(stockees.first)
        let brute = try #require(a.geometry)
        #expect(AnnotationGeometry(json: brute)?.sha256 == autre)

        let absent = try await outil.reconnaitre(documentId: docId, sha256: autre, pdfAt: tmp.appendingPathComponent("nulle-part.pdf").path, in: db, appliquer: true)
        #expect(absent.reconnues == 0 && absent.modifiees == 0)
        let finale = try await AnnotationStore(db: db).annotations(documentId: docId)
        #expect(finale.first?.geometry == a.geometry)
    }
}

extension AnnotationLecteurTests {
    /// Comme `bibliotheque`, pour les suites voisines.
    fileprivate func biblio(path: String) async throws -> (CatalogDatabase, UUID) {
        try await bibliotheque(hash: empreinte, path: path)
    }
}
#endif
