import Foundation

/// La géométrie d'une annotation, pour le lecteur en ligne (T-037).
///
/// Elle n'est jamais l'ancre : le TEXTE fait foi (`AnnotationAnchor`). Elle
/// accélère — et rattrape les citations que le texte seul ne retrouve pas. Elle
/// n'est valable que pour le fichier où elle a été mesurée (`sha256`) ; sur un
/// autre fichier, le lecteur l'ignore et retombe sur le texte.
///
/// Les rectangles sont ceux de la cropBox **non tournée** de la page, normalisés
/// de 0 à 1, origine en haut à gauche (`[x, y, largeur, hauteur]`), quatre
/// décimales. Le lecteur en tire les coordonnées de son propre affichage, rotation
/// comprise. Au plus 4 pages et 64 rectangles par page.
public struct AnnotationGeometry: Codable, Equatable, Sendable {
    public struct PageRects: Codable, Equatable, Sendable {
        public var page: Int
        public var rects: [[Double]]

        public init(page: Int, rects: [[Double]]) {
            self.page = page
            self.rects = rects
        }
    }

    public var sha256: String
    public var pages: [PageRects]

    public static let maxPages = 4
    public static let maxRectsPerPage = 64

    public init(sha256: String, pages: [PageRects]) {
        self.sha256 = sha256
        self.pages = pages
    }

    /// La géométrie d'une annotation sur une seule page (le cas d'une annotation
    /// de PDF), à partir de rectangles de l'espace de la page (origine en bas à
    /// gauche, non tournés) et de la cropBox de cette page (même espace). Nil si
    /// rien d'exploitable reste, ou si les rectangles dépassent la borne après
    /// fusion des morceaux d'une même ligne : le texte prend alors le relais.
    public static func make(sha256: String, page: Int, rects: [CGRect], cropBox: CGRect) -> AnnotationGeometry? {
        guard sha256.count == 64, page >= 1, cropBox.width > 0, cropBox.height > 0 else { return nil }
        let merged = mergeLines(rects)
        let normalized = normalize(merged, in: cropBox)
        guard !normalized.isEmpty, normalized.count <= maxRectsPerPage else { return nil }
        return AnnotationGeometry(sha256: sha256, pages: [PageRects(page: page, rects: normalized)])
    }

    /// Rectangles de la page → `[x, y, l, h]` normalisés dans la cropBox, origine
    /// en haut à gauche, bornés à la page, arrondis à 4 décimales. Écarte ce qui
    /// est vide ou hors de la page.
    public static func normalize(_ rects: [CGRect], in cropBox: CGRect) -> [[Double]] {
        func r4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        var sortie: [[Double]] = []
        for rect in rects {
            guard rect.width > 0, rect.height > 0 else { continue }
            let x0 = clamp((rect.minX - cropBox.minX) / cropBox.width)
            let x1 = clamp((rect.maxX - cropBox.minX) / cropBox.width)
            let y0 = clamp((cropBox.maxY - rect.maxY) / cropBox.height)
            let y1 = clamp((cropBox.maxY - rect.minY) / cropBox.height)
            let w = r4(x1 - x0), h = r4(y1 - y0)
            guard w > 0, h > 0 else { continue }
            sortie.append([r4(x0), r4(y0), w, h])
        }
        return sortie
    }

    /// Réunit les morceaux d'une même ligne (recouvrement vertical d'au moins la
    /// moitié de la plus petite hauteur, écart horizontal d'une espace ou moins) :
    /// Aperçu ou Skim posent parfois un rectangle par mot. Rend les lignes de
    /// haut en bas, de gauche à droite. Au-delà de 1 000 rectangles, rend [] :
    /// ce n'est plus un surlignement qu'on peut dire sans le texte.
    public static func mergeLines(_ rects: [CGRect]) -> [CGRect] {
        var items = rects.filter { $0.width > 0 && $0.height > 0 && $0.minX.isFinite && $0.minY.isFinite }
        guard items.count <= 1_000 else { return [] }
        var changed = true
        while changed {
            changed = false
            outer: for i in 0 ..< items.count {
                for j in (i + 1) ..< items.count where sameLine(items[i], items[j]) {
                    items[i] = items[i].union(items[j])
                    items.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return items.sorted { a, b in
            if abs(a.midY - b.midY) > min(a.height, b.height) / 2 { return a.midY > b.midY }
            return a.minX < b.minX
        }
    }

    private static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap >= min(a.height, b.height) / 2 else { return false }
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        return gap <= max(a.height, b.height) * 0.75
    }

    // MARK: - JSON

    /// Le JSON stocké (`annotation.geometry`) et publié (`geometrie`) : clés triées.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Relit une géométrie ; nil si le texte n'en est pas une, ou si elle sort des bornes.
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AnnotationGeometry.self, from: data),
              decoded.isValid
        else { return nil }
        self = decoded
    }

    /// Dans les bornes : 64 caractères hexadécimaux, 1 à 4 pages, 1 à 64 rectangles
    /// par page, chaque rectangle de quatre nombres entre 0 et 1.
    public var isValid: Bool {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              (1 ... Self.maxPages).contains(pages.count) else { return false }
        return pages.allSatisfy { p in
            p.page >= 1 && (1 ... Self.maxRectsPerPage).contains(p.rects.count)
                && p.rects.allSatisfy { r in r.count == 4 && r.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && r[2] > 0 && r[3] > 0 }
        }
    }
}
