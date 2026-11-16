import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Les jumeaux sans texte : deux scans du même livre, que la comparaison du
/// texte (`ContentCheck`) ne voit pas, faute de texte. Le 16/11/2026, deux
/// copies du même Métayer (372 pages, l'une réexportée en A4 par Aperçu avec
/// des surlignements en plus) portaient chacune sa fiche et sa clé.
///
/// On compare ce que le fichier montre. Même nombre de pages ; puis, sur des
/// pages témoins réparties dans tout le livre, réduites à une vignette grise :
///   — le **profil d'encre** (la noirceur moyenne de chaque page) suit la même
///     courbe d'un bout à l'autre : pages blanches, débuts de chapitre et
///     figures tombent aux mêmes endroits (mesuré sur le Métayer : corrélation
///     1,00 entre les jumeaux, 0,03 avec le même livre décalé de trois pages) ;
///   — et les pages se ressemblent une à une.
/// La taille des pages ne compte pas : une réexportation la change. Un
/// surlignement ou une recompression ne changent presque rien à une vignette.
public enum ImageTwins {
    /// En dessous, la courbe est trop courte pour distinguer deux livres.
    static let minimumPages = 12
    /// Pages témoins lues, au plus.
    static let maximumWitnesses = 40
    /// Côté de la vignette, en points de gris.
    static let side = 24
    /// Corrélation minimale des profils d'encre.
    static let profileThreshold = 0.95
    /// Ressemblance médiane minimale des pages témoins, une à une.
    static let pageThreshold = 0.6

    /// Ce qu'on retient d'un PDF pour le comparer.
    public struct Print: Sendable, Equatable {
        public let pages: Int
        /// Les vignettes des pages témoins (`side` × `side` octets chacune).
        public let thumbnails: [[UInt8]]

        public init(pages: Int, thumbnails: [[UInt8]]) {
            self.pages = pages
            self.thumbnails = thumbnails
        }
    }

    /// Les pages témoins d'un livre de `count` pages (numérotées de 1),
    /// régulièrement réparties, hors des deux premières et des deux dernières
    /// (couvertures et pages d'éditeur). Pur.
    static func witnesses(count: Int) -> [Int] {
        guard count >= minimumPages else { return [] }
        let first = 3, last = count - 2
        let n = min(maximumWitnesses, last - first + 1)
        guard n > 1 else { return [first] }
        return (0..<n).map { first + $0 * (last - first) / (n - 1) }
    }

    /// Corrélation de deux suites de même longueur (de −1 à 1) ; 0 si l'une ne
    /// varie pas. Pur.
    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        guard da > 0, db > 0 else { return 0 }
        return num / (da * db).squareRoot()
    }

    /// Deux empreintes désignent-elles le même livre ? Pur.
    static func same(_ a: Print, _ b: Print) -> Bool {
        guard a.pages == b.pages, a.pages >= minimumPages,
              a.thumbnails.count == b.thumbnails.count, a.thumbnails.count >= 8 else { return false }
        let ink = { (p: Print) in p.thumbnails.map { t in Double(t.reduce(0) { $0 + Int($1) }) / Double(max(t.count, 1)) } }
        guard correlation(ink(a), ink(b)) >= profileThreshold else { return false }
        let likeness = zip(a.thumbnails, b.thumbnails)
            .map { correlation($0.map(Double.init), $1.map(Double.init)) }.sorted()
        return likeness[likeness.count / 2] >= pageThreshold
    }

    /// Range les fichiers par livre : chaque groupe rendu compte au moins deux
    /// éléments. Pur.
    static func groups<ID>(_ prints: [(id: ID, print: Print)]) -> [[ID]] {
        var byPages: [Int: [(id: ID, print: Print)]] = [:]
        for p in prints where p.print.pages >= minimumPages { byPages[p.print.pages, default: []].append(p) }
        var result: [[ID]] = []
        for (_, candidates) in byPages.sorted(by: { $0.key < $1.key }) where candidates.count > 1 {
            var clusters: [[(id: ID, print: Print)]] = []
            for c in candidates {
                if let i = clusters.firstIndex(where: { same($0[0].print, c.print) }) { clusters[i].append(c) }
                else { clusters.append([c]) }
            }
            result += clusters.filter { $0.count > 1 }.map { $0.map(\.id) }
        }
        return result
    }

    #if canImport(CoreGraphics)
    /// Le nombre de pages, sans rien dessiner : de quoi écarter presque tous
    /// les fichiers avant de rendre la moindre vignette.
    static func pageCount(of url: URL) -> Int? {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages >= minimumPages else { return nil }
        return document.numberOfPages
    }

    /// L'empreinte complète, vignettes comprises.
    public static func print(of url: URL) -> Print? {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages >= minimumPages else { return nil }
        var thumbnails: [[UInt8]] = []
        for n in witnesses(count: document.numberOfPages) {
            guard let page = document.page(at: n), let t = thumbnail(page) else { return nil }
            thumbnails.append(t)
        }
        return Print(pages: document.numberOfPages, thumbnails: thumbnails)
    }

    /// Une page ramenée à `side` × `side` gris, sur fond blanc.
    static func thumbnail(_ page: CGPDFPage) -> [UInt8]? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            // La page entière dans le carré, redressée (une page tournée garde son contenu droit).
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: side, height: side),
                                                         rotate: 0, preserveAspectRatio: false))
            context.drawPDFPage(page)
            return true
        }
        return drawn ? pixels : nil
    }

    /// Les groupes de jumeaux parmi des PDF sans texte. Les vignettes ne sont
    /// rendues que pour les fichiers qui ont le même nombre de pages qu'un autre.
    public static func find<ID>(among files: [(id: ID, url: URL)]) -> [[ID]] {
        var byPages: [Int: [(id: ID, url: URL)]] = [:]
        for f in files {
            guard let n = pageCount(of: f.url) else { continue }
            byPages[n, default: []].append(f)
        }
        var prints: [(id: ID, print: Print)] = []
        for (_, candidates) in byPages where candidates.count > 1 {
            for c in candidates { if let p = print(of: c.url) { prints.append((c.id, p)) } }
        }
        return groups(prints)
    }
    #else
    // Sous Linux (WP-34) : pas de rendu de page ; aucun jumeau d'image n'est dit.
    public static func find<ID>(among files: [(id: ID, url: URL)]) -> [[ID]] { [] }
    #endif
}
