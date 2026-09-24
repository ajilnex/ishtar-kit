import CoreGraphics
import Foundation

/// Ce qu'on mesure sur une image candidate au rôle de couverture.
///
/// Rien que des nombres : c'est ce qui rend le jugement testable sans image, et
/// donc vérifiable. La lecture des pixels est reléguée à une fonction bête
/// (`CoverInspector.statistics`) ; la décision, elle, est pure.
public struct CoverPageStatistics: Equatable, Sendable {
    /// Fraction de pixels qui ne sont PAS du blanc de papier (luminance < 0,92).
    public var inkCoverage: Double
    /// Luminance moyenne, de 0 (noir) à 1 (blanc).
    public var meanLuminance: Double
    /// Écart-type de la luminance : une page unie est proche de 0.
    public var luminanceSpread: Double
    /// Saturation moyenne. Un scan en niveaux de gris est proche de 0 ; une
    /// couverture d'éditeur monte le plus souvent au-dessus.
    public var meanSaturation: Double
    /// Fraction de pixels tombant dans la tranche de luminance dominante.
    /// Proche de 1 = un aplat, quelle qu'en soit la couleur.
    public var dominantBandFraction: Double

    public init(inkCoverage: Double, meanLuminance: Double, luminanceSpread: Double,
                meanSaturation: Double, dominantBandFraction: Double) {
        self.inkCoverage = inkCoverage
        self.meanLuminance = meanLuminance
        self.luminanceSpread = luminanceSpread
        self.meanSaturation = meanSaturation
        self.dominantBandFraction = dominantBandFraction
    }
}

/// Pourquoi une image a été refusée comme couverture. Toujours nommé : refuser
/// sans dire pourquoi rendrait l'entonnoir impossible à régler, et l'utilisateur
/// ne saurait pas si le tort est au fichier ou au réglage.
public enum CoverRejection: String, Equatable, Sendable {
    /// Presque rien d'imprimé : page de garde, feuille blanche, scan raté.
    case nearBlank
    /// Un aplat : page entièrement noire, bleue, grise — un scan qui a glissé.
    case uniformField
    /// Peu d'encre ET aucune couleur : la signature d'une page de titre scannée
    /// ou d'un bandeau de site de partage, pas d'une couverture d'éditeur.
    /// Ce motif n'est écarté qu'au-delà d'une certaine exigence : beaucoup de
    /// couvertures anciennes sont, légitimement, du texte noir sur blanc.
    case sparseGrayscalePage
}

/// L'examen de la page 1 (WP-33, décision d'Aubin du 29/07).
///
/// **Pourquoi cet étage existe** : jusqu'ici, tout ce que QuickLook rendait
/// était accepté sans regarder. Un scan blanc, un tampon de bibliothèque ou un
/// bandeau de téléchargement devenaient la « couverture » du livre. Refusés, ils
/// laissent la place à l'étage suivant de l'entonnoir — et in fine à une
/// couverture composée, qui est toujours présentable.
///
/// **Ce que cet examen ne sait PAS faire, et ne prétend pas faire** : lire. Il
/// ne reconnaît pas un logo, ne comprend pas un titre. Il mesure de la matière
/// imprimée et de la couleur. Un faux positif reste possible ; c'est pourquoi la
/// sévérité est un réglage et non une constante, et pourquoi une couverture
/// déposée à la main l'emporte toujours (étage 0).
public enum CoverInspector {

    /// Verdict : `nil` si l'image peut servir de couverture, sinon la raison.
    ///
    /// `strictness` va de 0 (on ne refuse que l'indéfendable) à 1 (on exige une
    /// vraie couverture illustrée). Les seuils s'interpolent entre les deux —
    /// une seule molette pour l'utilisateur, pas six.
    public static func judge(_ stats: CoverPageStatistics,
                             strictness: Double) -> CoverRejection? {
        let severity = min(max(strictness, 0), 1)

        // 1. Presque rien d'imprimé. Le seuil monte avec la sévérité : de 1,5 %
        //    (on ne refuse qu'une feuille quasi vierge) à 8 %.
        let blankCeiling = interpolate(from: 0.015, to: 0.08, at: severity)
        if stats.inkCoverage < blankCeiling { return .nearBlank }

        // 2. Un aplat. Indépendant de la sévérité : une page unie n'est JAMAIS
        //    une couverture, quelle que soit l'indulgence qu'on veuille bien
        //    avoir. Les deux conditions comptent — une couverture peut être très
        //    sombre (donc peu d'écart) sans être unie (donc bande dominante
        //    modérée).
        if stats.dominantBandFraction > 0.96 && stats.luminanceSpread < 0.04 {
            return .uniformField
        }

        // 3. Peu d'encre et pas de couleur : page de titre scannée. Ce motif
        //    n'est écarté qu'au-delà de la moitié de la molette, parce que les
        //    couvertures sobres — celles des collections savantes — y
        //    ressemblent beaucoup.
        guard severity > 0.5 else { return nil }
        let sparseCeiling = interpolate(from: 0.10, to: 0.22, at: (severity - 0.5) * 2)
        if stats.inkCoverage < sparseCeiling && stats.meanSaturation < 0.06 {
            return .sparseGrayscalePage
        }

        return nil
    }

    private static func interpolate(from low: Double, to high: Double, at t: Double) -> Double {
        low + (high - low) * min(max(t, 0), 1)
    }

    // MARK: Lecture des pixels

    /// Mesure une image. Sous-échantillonnée à 64×64 : on cherche des masses,
    /// pas des détails, et un scan de 300 ppp coûterait cher pour rien.
    ///
    /// `nil` si l'image ne peut pas être lue — dans ce cas on ne refuse rien :
    /// ne pas savoir mesurer n'est pas une raison de rejeter.
    public static func statistics(of image: CGImage) -> CoverPageStatistics? {
        let side = 64
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var luminances = [Double]()
        luminances.reserveCapacity(side * side)
        var saturationSum = 0.0
        var inked = 0
        // 20 tranches de luminance : assez fin pour distinguer un aplat d'un
        // dégradé, assez grossier pour que le bruit d'un scan ne le disperse pas.
        var bands = [Int](repeating: 0, count: 20)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255

            // Luminance perceptuelle (Rec. 601) : le vert pèse plus que le bleu,
            // comme dans l'œil.
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            luminances.append(luminance)
            if luminance < 0.92 { inked += 1 }

            let maxChannel = max(r, g, b), minChannel = min(r, g, b)
            saturationSum += maxChannel > 0 ? (maxChannel - minChannel) / maxChannel : 0

            bands[min(Int(luminance * 20), 19)] += 1
        }

        let count = Double(luminances.count)
        guard count > 0 else { return nil }
        let mean = luminances.reduce(0, +) / count
        let variance = luminances.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count

        return CoverPageStatistics(
            inkCoverage: Double(inked) / count,
            meanLuminance: mean,
            luminanceSpread: variance.squareRoot(),
            meanSaturation: saturationSum / count,
            dominantBandFraction: Double(bands.max() ?? 0) / count)
    }
}
