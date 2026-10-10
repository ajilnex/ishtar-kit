#if canImport(PDFKit)
import CoreGraphics
import PDFKit
#endif
import Foundation
import IshtarCatalog

/// Récupère les annotations DÉJÀ présentes dans un PDF (surlignements faits
/// dans Aperçu, Skim, Adobe…) et les convertit en surlignements Ishtar,
/// ancrés PAR LE TEXTE. Le fichier n'est jamais modifié : on ne fait que lire.
public struct PDFAnnotationImporter: Sendable {
    public init() {}

    /// Types de balisage et de note retenus ; tout le reste (liens, tampons,
    /// dessins, champs de formulaire) est ignoré.
    private static let markupTypes: Set<String> = [
        "Highlight", "Underline", "StrikeOut", "Text", "FreeText",
    ]

    /// Longueur du contexte conservé de part et d'autre de la citation.
    private static let contextLength = 48

    /// Une annotation de balisage lue dans un PDF, avec ce qu'il faut pour la
    /// reconnaître (page + citation) et pour la dessiner (rectangles).
    public struct Markup: Sendable {
        public var page: Int
        public var quote: String
        public var prefix: String?
        public var suffix: String?
        public var note: String?
        /// Les rectangles du passage, dans l'espace de la page (origine en bas à
        /// gauche, non tourné). Nil quand ils ne se laissent pas vérifier.
        public var rects: [CGRect]?
        /// La cropBox de la page, dans le même espace.
        public var cropBox: CGRect

        /// La clé qui reconnaît une annotation importée : page + citation repliée.
        public var key: String { PDFAnnotationImporter.key(page: page, quote: quote) }

        /// La géométrie pour le lecteur en ligne, mesurée sur le fichier d'empreinte `sha256`.
        public func geometry(sha256: String) -> AnnotationGeometry? {
            guard let rects else { return nil }
            return AnnotationGeometry.make(sha256: sha256, page: page, rects: rects, cropBox: cropBox)
        }
    }

    /// Les annotations de balisage d'un PDF, telles que le fichier les porte.
    /// Pur : ne touche ni le fichier ni la base. [] si le PDF est absent ou sans
    /// annotation (et sous Linux, sans PDFKit).
    public func markups(fromPDFAt path: String) -> [Markup] {
        #if canImport(PDFKit)
        guard FileManager.default.fileExists(atPath: path),
              let document = PDFDocument(url: URL(fileURLWithPath: path))
        else { return [] }

        var lues: [Markup] = []
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageText = Self.compact(page.string ?? "")
            let cropBox = page.bounds(for: .cropBox)

            for annotation in page.annotations {
                guard let type = annotation.type, Self.markupTypes.contains(type) else { continue }

                let (text, rects) = Self.selection(of: annotation, on: page)
                let quote = Self.compact(text)
                // Sans citation, pas d'ancrage : on n'invente jamais.
                guard !quote.isEmpty else { continue }

                let note = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines)
                let context = Self.context(of: quote, in: pageText)

                lues.append(Markup(
                    page: pageIndex + 1,
                    quote: quote,
                    prefix: context.prefix,
                    suffix: context.suffix,
                    note: (note?.isEmpty ?? true) ? nil : note,
                    rects: rects,
                    cropBox: cropBox))
            }
        }
        return lues
        #else
        // Sous Linux (l'outil du serveur, WP-34) : pas de lecteur d'annotations
        // PDF. Elles restent dans le fichier, intactes ; rien n'est inventé.
        return []
        #endif
    }

    /// Les annotations de balisage d'un PDF, converties en surlignements Ishtar
    /// (`origin = "pdf"`). Avec `sha256` (l'empreinte du fichier), elles portent
    /// aussi leur géométrie. Pur : ne touche ni le fichier ni la base.
    public func annotations(fromPDFAt path: String, documentId: UUID, sha256: String? = nil) -> [Annotation] {
        markups(fromPDFAt: path).map { markup in
            Annotation(
                documentId: documentId,
                pageNumber: markup.page,
                quote: markup.quote,
                prefix: markup.prefix,
                suffix: markup.suffix,
                note: markup.note,
                color: nil,
                origin: "pdf",
                geometry: sha256.flatMap { markup.geometry(sha256: $0)?.json })
        }
    }

    /// Importe dans le catalogue en ignorant ce qui s'y trouve déjà (même
    /// citation, même page). Idempotent. Retourne le nombre réellement ajouté.
    @discardableResult
    public func importAnnotations(fromPDFAt path: String, documentId: UUID,
                                  into db: CatalogDatabase) async throws -> Int
    {
        let sha = try await db.pool.read { conn in
            try String.fetchOne(conn, sql: "SELECT contentHash FROM document WHERE id = ?", arguments: [documentId])
        }
        let candidates = annotations(fromPDFAt: path, documentId: documentId, sha256: sha)
        guard !candidates.isEmpty else { return 0 }

        let store = AnnotationStore(db: db)
        var seen = Set(try await store.annotations(documentId: documentId).map { Self.key(page: $0.pageNumber, quote: $0.quote) })

        var added = 0
        for candidate in candidates {
            let key = Self.key(page: candidate.pageNumber, quote: candidate.quote)
            guard !seen.contains(key) else { continue }
            _ = try await store.add(candidate)
            seen.insert(key)
            added += 1
        }
        return added
    }

    // MARK: - Texte visé

    #if canImport(PDFKit)

    /// Le texte réellement couvert par l'annotation, et les rectangles d'où il vient.
    /// Les quadPoints décrivent les lignes surlignées ; le `bounds` seul happerait
    /// tout le bloc. Les rectangles ne sont rendus que s'ils tiennent dans le
    /// `bounds` de l'annotation (à 2 points près) : un rectangle qui en sort
    /// vient d'une lecture ambiguë des quadPoints, et ne doit pas être dessiné.
    static func selection(of annotation: PDFAnnotation, on page: PDFPage) -> (text: String, rects: [CGRect]?) {
        let points = annotation.quadrilateralPoints ?? []
        guard points.count >= 4 else {
            return (page.selection(for: annotation.bounds)?.string ?? "", [annotation.bounds])
        }

        var pieces: [String] = []
        var rects: [CGRect] = []
        for start in stride(from: 0, to: points.count - points.count % 4, by: 4) {
            let corners = points[start ..< (start + 4)].map { $0.pointValue }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            var rect = CGRect(x: xs.min()!, y: ys.min()!,
                              width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            // PDFKit rend ces points relatifs au `bounds` de l'annotation ;
            // certains fichiers les portent en coordonnées de page. On replace
            // le rect dans la page quand il tombe manifestement à côté.
            if !annotation.bounds.intersects(rect) {
                rect = rect.offsetBy(dx: annotation.bounds.origin.x, dy: annotation.bounds.origin.y)
            }
            rects.append(rect)
            if let text = page.selection(for: rect)?.string, !text.isEmpty {
                pieces.append(text)
            }
        }
        let tolerant = annotation.bounds.insetBy(dx: -2, dy: -2)
        let verified = rects.allSatisfy { tolerant.contains($0) } ? rects : nil
        if pieces.isEmpty {
            return (page.selection(for: annotation.bounds)?.string ?? "", verified)
        }
        return (pieces.joined(separator: " "), verified)
    }

    #endif

    // MARK: - Outils

    /// Blancs compactés : c'est la forme sous laquelle une citation s'ancre.
    private static func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Contexte avant/après la citation dans le texte de la page ; nil si la
    /// citation n'y est pas retrouvée.
    private static func context(of quote: String, in pageText: String)
        -> (prefix: String?, suffix: String?)
    {
        guard !pageText.isEmpty,
              let range = pageText.range(of: quote,
                                         options: [.caseInsensitive, .diacriticInsensitive])
        else { return (nil, nil) }

        let before = String(pageText[pageText.startIndex ..< range.lowerBound].suffix(contextLength))
        let after = String(pageText[range.upperBound ..< pageText.endIndex].prefix(contextLength))
        return (before.isEmpty ? nil : before, after.isEmpty ? nil : after)
    }

    /// Clé de doublon : citation repliée (casse, diacritiques) + page.
    static func key(page: Int?, quote: String) -> String {
        let folded = compact(quote)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return "\(page.map(String.init) ?? "-")\u{1}\(folded)"
    }
}
