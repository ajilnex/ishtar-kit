import CoreGraphics
import Foundation
import Testing
@testable import IshtarIngest

// MARK: - Le jugement, sans aucune image

/// Le jugement est une fonction pure de cinq nombres : il se teste donc
/// exhaustivement, sans fabriquer de PNG. C'est tout l'intérêt d'avoir séparé
/// la mesure de la décision.
@Suite("Couvertures — l'examen de la page 1")
struct CoverInspectorTests {

    /// Une page d'un livre ordinaire : beaucoup d'encre, du relief, un peu de
    /// couleur. Elle doit passer à toutes les exigences, sinon le réglage
    /// « sévère » serait inutilisable.
    private var plausibleCover: CoverPageStatistics {
        CoverPageStatistics(inkCoverage: 0.62, meanLuminance: 0.48,
                            luminanceSpread: 0.24, meanSaturation: 0.31,
                            dominantBandFraction: 0.19)
    }

    @Test("Une vraie couverture passe, quelle que soit l'exigence")
    func realCoverAlwaysPasses() {
        for strictness in [0.0, 0.25, 0.5, 0.75, 1.0] {
            #expect(CoverInspector.judge(plausibleCover, strictness: strictness) == nil,
                    "refusée à l'exigence \(strictness)")
        }
    }

    @Test("Une feuille quasi vierge est refusée même à l'exigence la plus basse")
    func nearBlankIsAlwaysRejected() {
        let blank = CoverPageStatistics(inkCoverage: 0.004, meanLuminance: 0.99,
                                        luminanceSpread: 0.01, meanSaturation: 0.0,
                                        dominantBandFraction: 0.99)
        #expect(CoverInspector.judge(blank, strictness: 0) == .nearBlank)
        #expect(CoverInspector.judge(blank, strictness: 1) == .nearBlank)
    }

    /// Le cas décisif du réglage : une page peu imprimée mais pas vide. C'est
    /// exactement ce que la molette gouverne.
    @Test("Une page peu imprimée passe en tolérante, tombe en sévère")
    func strictnessGovernsTheMiddleGround() {
        let faint = CoverPageStatistics(inkCoverage: 0.05, meanLuminance: 0.93,
                                        luminanceSpread: 0.09, meanSaturation: 0.01,
                                        dominantBandFraction: 0.82)
        #expect(CoverInspector.judge(faint, strictness: 0) == nil)
        #expect(CoverInspector.judge(faint, strictness: 1) != nil)
    }

    @Test("Un aplat est refusé indépendamment de l'exigence")
    func uniformFieldIsRejectedRegardlessOfStrictness() {
        // Page entièrement noire : beaucoup d'« encre », donc l'étage « quasi
        // vierge » ne l'attrape pas — c'est bien l'uniformité qui la condamne.
        let solidBlack = CoverPageStatistics(inkCoverage: 1.0, meanLuminance: 0.02,
                                            luminanceSpread: 0.005, meanSaturation: 0.0,
                                            dominantBandFraction: 0.995)
        #expect(CoverInspector.judge(solidBlack, strictness: 0) == .uniformField)
        #expect(CoverInspector.judge(solidBlack, strictness: 1) == .uniformField)
    }

    @Test("Une couverture très sombre mais travaillée n'est pas prise pour un aplat")
    func darkButDetailedCoverSurvives() {
        let darkCover = CoverPageStatistics(inkCoverage: 0.97, meanLuminance: 0.14,
                                            luminanceSpread: 0.11, meanSaturation: 0.22,
                                            dominantBandFraction: 0.44)
        #expect(CoverInspector.judge(darkCover, strictness: 1) == nil)
    }

    /// La sobriété n'est pas un défaut : les collections savantes publient du
    /// texte noir sur blanc. Ce motif ne doit pas être écarté sous la moitié de
    /// la molette, sans quoi le réglage par défaut mangerait de vraies couvertures.
    @Test("Une couverture typographique sobre survit jusqu'à la moitié de la molette")
    func soberTypographicCoverSurvivesDefaultSettings() {
        let sober = CoverPageStatistics(inkCoverage: 0.14, meanLuminance: 0.88,
                                        luminanceSpread: 0.16, meanSaturation: 0.02,
                                        dominantBandFraction: 0.71)
        #expect(CoverInspector.judge(sober, strictness: 0.5) == nil)
    }

    @Test("Les exigences hors bornes ne font pas dérailler le jugement")
    func outOfRangeStrictnessIsClamped() {
        #expect(CoverInspector.judge(plausibleCover, strictness: -5) == nil)
        #expect(CoverInspector.judge(plausibleCover, strictness: 42) == nil)
    }
}

// MARK: - La mesure, sur des images fabriquées

@Suite("Couvertures — la mesure des pixels")
struct CoverStatisticsTests {

    /// Une image d'un seul aplat, fabriquée en mémoire.
    private func solid(red: Double, green: Double, blue: Double) -> CGImage {
        let side = 32
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    /// Deux moitiés franches : de l'encre sur la moitié basse seulement.
    private func halfInked() -> CGImage {
        let side = 32
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        return context.makeImage()!
    }

    @Test("Une page blanche : aucune encre, aucune couleur, tout dans une bande")
    func whitePageMeasuredAsBlank() throws {
        let stats = try #require(CoverInspector.statistics(of: solid(red: 1, green: 1, blue: 1)))
        #expect(stats.inkCoverage < 0.01)
        #expect(stats.meanLuminance > 0.98)
        #expect(stats.luminanceSpread < 0.01)
        #expect(stats.meanSaturation < 0.01)
        #expect(stats.dominantBandFraction > 0.98)
        // Et le jugement doit suivre la mesure : c'est le bout en bout.
        #expect(CoverInspector.judge(stats, strictness: 0) == .nearBlank)
    }

    @Test("Une page noire : de l'encre partout, mais unie — donc refusée")
    func blackPageMeasuredAsUniform() throws {
        let stats = try #require(CoverInspector.statistics(of: solid(red: 0, green: 0, blue: 0)))
        #expect(stats.inkCoverage > 0.98)
        #expect(stats.dominantBandFraction > 0.98)
        #expect(CoverInspector.judge(stats, strictness: 0) == .uniformField)
    }

    @Test("Un aplat de couleur saturée est mesuré comme tel")
    func saturatedSolidIsMeasured() throws {
        let stats = try #require(CoverInspector.statistics(of: solid(red: 0.1, green: 0.2, blue: 0.9)))
        #expect(stats.meanSaturation > 0.7)
        #expect(CoverInspector.judge(stats, strictness: 0) == .uniformField)
    }

    @Test("Moitié encrée : la couverture d'encre vaut la moitié, et rien n'est uni")
    func halfInkedIsMeasuredHalfway() throws {
        let stats = try #require(CoverInspector.statistics(of: halfInked()))
        #expect(abs(stats.inkCoverage - 0.5) < 0.06)
        #expect(stats.luminanceSpread > 0.4)      // deux extrêmes, donc l'écart maximal
        #expect(stats.dominantBandFraction < 0.6)
        #expect(CoverInspector.judge(stats, strictness: 1) == nil)
    }
}
