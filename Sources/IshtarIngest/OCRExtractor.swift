import CoreGraphics
import Foundation
import GRDB
import IshtarCatalog
import PDFKit
import Vision

/// OCR à la demande d'un PDF muet (WP-11a). Vision, entièrement LOCAL —
/// jamais de réseau. Même écriture que ExtractionPipeline (pages effacées
/// puis réinsérées dans une transaction), mais déclenché par un geste
/// explicite de l'utilisateur, jamais par le scan ni l'indexation de fond.
public struct OCRExtractor: Sendable {
    public init() {}

    /// OCRise le document. Retourne le nombre de pages où du texte a été
    /// reconnu ; nil si le document est introuvable ou n'est pas un PDF.
    @discardableResult
    public func extract(
        documentId: UUID, into db: CatalogDatabase,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int? {
        guard let document = try await db.pool.read({ try Document.fetchOne($0, key: documentId) }),
              document.format == .pdf
        else { return nil }
        guard let pdf = PDFDocument(url: URL(fileURLWithPath: document.filePath)) else { return nil }

        let pageCount = pdf.pageCount
        var recognized: [(number: Int, content: String)] = []

        for pageIndex in 0 ..< pageCount {
            if Task.isCancelled { break }
            guard let page = pdf.page(at: pageIndex) else { continue }

            // 1. Rendu bitmap sans AppKit (CGContext, fond blanc, échelle 2.5).
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.5
            let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
            guard width > 0, height > 0,
                  let ctx = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { continue }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            if let ref = page.pageRef { ctx.drawPDFPage(ref) }
            guard let image = ctx.makeImage() else { continue }

            // 2. Reconnaissance Vision (locale, français puis anglais).
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            // 3. On ne retient que les pages effectivement porteuses de texte.
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recognized.append((number: pageIndex + 1, content: text))
            }
            progress?(pageIndex + 1, pageCount)
        }

        // Écriture dans UNE transaction, comme ExtractionPipeline : on repart
        // d'une table de pages nette pour ce document, on réinsère, puis on
        // éteint needsOCR sur le document frais.
        let pages = recognized
        try await db.pool.write { conn in
            try DocumentPage.filter(Column("documentId") == documentId).deleteAll(conn)
            for page in pages {
                try DocumentPage(documentId: documentId, pageNumber: page.number, content: page.content)
                    .insert(conn)
            }
            guard var fresh = try Document.fetchOne(conn, key: documentId) else { return }
            fresh.isTextExtracted = true
            fresh.needsOCR = false
            try fresh.update(conn)
        }

        return recognized.count
    }
}
