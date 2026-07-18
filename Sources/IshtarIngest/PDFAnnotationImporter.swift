import CoreGraphics
import Foundation
import IshtarCatalog
import PDFKit

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

    /// Les annotations de balisage d'un PDF, converties. Pur : ne touche ni le
    /// fichier ni la base. Retourne [] si le PDF est absent ou sans annotation.
    public func annotations(fromPDFAt path: String, documentId: UUID) -> [Annotation] {
        guard FileManager.default.fileExists(atPath: path),
              let document = PDFDocument(url: URL(fileURLWithPath: path))
        else { return [] }

        var imported: [Annotation] = []
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageText = Self.compact(page.string ?? "")

            for annotation in page.annotations {
                guard let type = annotation.type, Self.markupTypes.contains(type) else { continue }

                let quote = Self.compact(Self.selectedText(of: annotation, on: page))
                // Sans citation, pas d'ancrage : on n'invente jamais.
                guard !quote.isEmpty else { continue }

                let note = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines)
                let context = Self.context(of: quote, in: pageText)

                imported.append(Annotation(
                    documentId: documentId,
                    pageNumber: pageIndex + 1,
                    quote: quote,
                    prefix: context.prefix,
                    suffix: context.suffix,
                    note: (note?.isEmpty ?? true) ? nil : note,
                    color: nil))
            }
        }
        return imported
    }

    /// Importe dans le catalogue en ignorant ce qui s'y trouve déjà (même
    /// citation, même page). Idempotent. Retourne le nombre réellement ajouté.
    @discardableResult
    public func importAnnotations(fromPDFAt path: String, documentId: UUID,
                                  into db: CatalogDatabase) async throws -> Int
    {
        let candidates = annotations(fromPDFAt: path, documentId: documentId)
        guard !candidates.isEmpty else { return 0 }

        let store = AnnotationStore(db: db)
        var seen = Set(try await store.annotations(documentId: documentId).map(Self.key))

        var added = 0
        for candidate in candidates {
            let key = Self.key(candidate)
            guard !seen.contains(key) else { continue }
            _ = try await store.add(candidate)
            seen.insert(key)
            added += 1
        }
        return added
    }

    // MARK: - Texte visé

    /// Le texte réellement couvert par l'annotation. Les quadPoints décrivent
    /// les lignes surlignées ; le `bounds` seul happerait tout le bloc.
    private static func selectedText(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        let points = annotation.quadrilateralPoints ?? []
        guard points.count >= 4 else {
            return page.selection(for: annotation.bounds)?.string ?? ""
        }

        var pieces: [String] = []
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
            if let text = page.selection(for: rect)?.string, !text.isEmpty {
                pieces.append(text)
            }
        }
        if pieces.isEmpty {
            return page.selection(for: annotation.bounds)?.string ?? ""
        }
        return pieces.joined(separator: " ")
    }

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
    private static func key(_ annotation: Annotation) -> String {
        let folded = compact(annotation.quote)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return "\(annotation.pageNumber.map(String.init) ?? "-")\u{1}\(folded)"
    }
}
