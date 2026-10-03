// Propre à macOS (cadres d'Apple ou démon) : hors de la suite Linux (WP-34).
#if canImport(Vision)
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import IshtarIngest

// MARK: - Banc de mesure OCR (WP-OCR-MESURE)

@Suite("OCR — moteurs comparables (rendu partagé, deux moteurs déterministes)")
struct OCRCompareTests {
    /// Même technique que le test de production : un PDF-image sans couche texte,
    /// où le texte est dessiné en Core Text puis inséré comme image.
    private func makeImagePDF(at url: URL, text: String) {
        let width = 800, height = 300
        let box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let bitmap = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return }
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(box)
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(attributed)
        bitmap.textPosition = CGPoint(x: 40, y: 120)
        CTLineDraw(line, bitmap)
        guard let image = bitmap.makeImage() else { return }

        var mediaBox = box
        guard let pdf = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
    }

    private func firstPageImage(text: String) throws -> CGImage {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ishtar-ocrcmp-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        makeImagePDF(at: tmp, text: text)
        let doc = try #require(PDFDocument(url: tmp))
        let page = try #require(doc.page(at: 0))
        return try #require(OCRExtractor.renderPage(page))
    }

    @Test("Le repli (VNRecognizeText) lit le scan — couvre le moteur legacy même sur macOS 26")
    func legacyLitLeScan() async throws {
        let image = try firstPageImage(text: "ISHTAR 1799")
        let text = try await OCRExtractor.recognize(in: image, engine: .legacyText).uppercased()
        #expect(text.contains("ISHTAR"))
        #expect(text.contains("1799"))
    }

    @Test("Le moteur de production (.best) lit le scan")
    func bestLitLeScan() async throws {
        let image = try firstPageImage(text: "ISHTAR 1799")
        let text = try await OCRExtractor.recognize(in: image, engine: .best).uppercased()
        #expect(text.contains("ISHTAR"))
        #expect(text.contains("1799"))
    }

    @Test("Sur macOS 26+, RecognizeDocumentsRequest lit le scan ; en deçà, il se déclare indisponible")
    func documentRequestSelonLaPlateforme() async throws {
        let image = try firstPageImage(text: "ISHTAR 1799")
        if #available(macOS 26, *) {
            let text = try await OCRExtractor.recognize(in: image, engine: .documentRequest).uppercased()
            #expect(text.contains("ISHTAR"))
            #expect(text.contains("1799"))
        } else {
            await #expect(throws: OCRExtractor.OCRError.self) {
                _ = try await OCRExtractor.recognize(in: image, engine: .documentRequest)
            }
        }
    }
}
#endif
