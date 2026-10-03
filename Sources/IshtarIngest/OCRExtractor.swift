import Foundation
import GRDB
import IshtarCatalog
#if canImport(Vision)
import CoreGraphics
import PDFKit
import Vision

/// OCR à la demande d'un PDF muet (WP-11a). Vision, entièrement LOCAL —
/// jamais de réseau. Même écriture que ExtractionPipeline (pages effacées
/// puis réinsérées dans une transaction), mais déclenché par un geste
/// explicite de l'utilisateur, jamais par le scan ni l'indexation de fond.
///
/// WP-OCR-VISION2 : sur macOS 26+, la reconnaissance passe par
/// `RecognizeDocumentsRequest` (regroupement en lignes/paragraphes, meilleure
/// tenue des mises en page) ; en deçà (macOS 14-15), repli sur
/// `VNRecognizeTextRequest`. Plancher macOS 14 tenu volontairement — des
/// chercheurs travaillent sur de vieux Mac (décision d'Aubin, 29/07). Les deux
/// moteurs sont DÉTERMINISTES : ils renoncent (trou) plutôt que d'inventer.
/// Aucun OCR génératif n'écrit ici — voir l'invariant du bloc OCR
/// (../../docs/30-CHANTIERS.md) et 40-GUIDE-AGENTS.md.
public struct OCRExtractor: Sendable {
    public init() {}

    /// OCRise le document. Retourne le nombre de pages où du texte a été
    /// reconnu ; nil si le document est introuvable ou n'est pas un PDF.
    @discardableResult
    public func extract(
        documentId: UUID, into db: CatalogDatabase,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int? {
        try Task.checkCancellation()
        guard let document = try await db.pool.read({ try Document.fetchOne($0, key: documentId) }),
              document.format == .pdf, !document.isMissing
        else { return nil }
        guard let pdf = PDFDocument(url: URL(fileURLWithPath: document.filePath)) else { return nil }

        let pageCount = pdf.pageCount
        var recognized: [(number: Int, content: String)] = []

        for pageIndex in 0 ..< pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: pageIndex) else { throw OCRError.pageUnavailable(pageIndex + 1) }

            // 1. Rendu bitmap partagé, puis reconnaissance (moteur de production).
            guard let image = Self.renderPage(page) else { throw OCRError.pageUnavailable(pageIndex + 1) }
            let text = try await Self.recognize(in: image, engine: .best)

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
        try Task.checkCancellation()
        guard !pages.isEmpty else { return 0 }
        try await db.pool.write { conn in
            try Task.checkCancellation()
            guard var fresh = try Document.fetchOne(conn, key: documentId),
                  !fresh.isMissing, fresh.contentHash == document.contentHash else { return }
            try DocumentPage.filter(Column("documentId") == documentId).deleteAll(conn)
            for page in pages {
                try DocumentPage(documentId: documentId, pageNumber: page.number, content: page.content)
                    .insert(conn)
            }
            fresh.isTextExtracted = true
            fresh.needsOCR = false
            try fresh.update(conn)
        }

        return recognized.count
    }

    /// Moteur de reconnaissance. `.best` est le choix de PRODUCTION : macOS 26+
    /// → `RecognizeDocumentsRequest`, sinon repli `VNRecognizeTextRequest`. Les
    /// deux autres cas forcent un moteur précis — réservés au banc de comparaison
    /// (WP-OCR-MESURE), jamais au chemin d'écriture ordinaire.
    public enum Engine: String, Sendable, CaseIterable {
        case best
        case documentRequest
        case legacyText
    }

    public enum OCRError: LocalizedError, Sendable {
        case engineUnavailable(String)
        case pageUnavailable(Int)

        public var errorDescription: String? {
            switch self {
            case .engineUnavailable(let message): return message
            case .pageUnavailable(let page):
                return "Impossible de rendre la page \(page). Le texte précédent est conservé."
            }
        }
    }

    /// Rend une page PDF en bitmap RGB (fond blanc, échelle 2.5 par défaut), sans
    /// AppKit. Partagé par l'extraction et le banc, pour que les moteurs comparés
    /// travaillent sur la MÊME image.
    public static func renderPage(_ page: PDFPage, scale: CGFloat = 2.5) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scaledWidth = bounds.width * scale, scaledHeight = bounds.height * scale
        guard scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth > 0, scaledHeight > 0,
              scaledWidth <= 16384, scaledHeight <= 16384,
              scaledWidth * scaledHeight <= 64_000_000,
              page.pageRef != nil else { return nil }
        let width = Int(scaledWidth), height = Int(scaledHeight)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        if let ref = page.pageRef { ctx.drawPDFPage(ref) }
        return ctx.makeImage()
    }

    /// Reconnaît le texte d'une image, moteur au choix. Local et déterministe :
    /// les deux moteurs renoncent (trou) plutôt que d'inventer.
    public static func recognize(in image: CGImage, engine: Engine = .best) async throws -> String {
        switch engine {
        case .best:
            if #available(macOS 26, iOS 26, *) { return try await documentRequest(image) }
            return try legacyText(image)
        case .documentRequest:
            if #available(macOS 26, iOS 26, *) { return try await documentRequest(image) }
            throw OCRError.engineUnavailable("RecognizeDocumentsRequest exige macOS 26+")
        case .legacyText:
            return try legacyText(image)
        }
    }

    /// macOS 26+ : `RecognizeDocumentsRequest`, dont le `transcript` restitue le
    /// texte du document dans l'ordre de lecture (lignes, paragraphes).
    @available(macOS 26, iOS 26, *)
    private static func documentRequest(_ image: CGImage) async throws -> String {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = [
            Locale.Language(identifier: "fr-FR"),
            Locale.Language(identifier: "en-US"),
        ]
        request.textRecognitionOptions.useLanguageCorrection = true
        let observations = try await request.perform(on: image)
        return observations
            .map { $0.document.text.transcript }
            .joined(separator: "\n")
    }

    /// Repli macOS 14-15 : `VNRecognizeTextRequest`, français puis anglais.
    private static func legacyText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

#else
/// Sous Linux (l'outil du serveur, WP-34) : pas de Vision. Même interface ;
/// l'OCR répond « moteur indisponible » et le document garde `needsOCR`
/// (tesseract, déjà sur le serveur, pourra prendre le relais — chantier à part).
public struct OCRExtractor: Sendable {
    public init() {}

    @discardableResult
    public func extract(
        documentId: UUID, into db: CatalogDatabase,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int? {
        throw OCRError.engineUnavailable("L'OCR n'est pas encore disponible sous Linux : le document reste marqué « à OCRiser ».")
    }

    public enum Engine: String, Sendable, CaseIterable {
        case best
        case documentRequest
        case legacyText
    }

    public enum OCRError: LocalizedError, Sendable {
        case engineUnavailable(String)
        case pageUnavailable(Int)

        public var errorDescription: String? {
            switch self {
            case .engineUnavailable(let message): return message
            case .pageUnavailable(let page):
                return "Impossible de rendre la page \(page). Le texte précédent est conservé."
            }
        }
    }
}
#endif
