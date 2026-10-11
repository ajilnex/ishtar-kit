import Foundation

/// Vecteurs du panneau blanc, ou de la cropBox PDF non tournée, origine haut gauche.
/// Le SVG est exclusivement dérivé des nombres validés et d'une palette fermée.
public struct AnnotationDrawing: Codable, Equatable, Sendable {
    public struct Stroke: Codable, Equatable, Sendable {
        public var couleur: String
        public var epaisseur: Double
        public var points: [[Double]]
        public init(couleur: String, epaisseur: Double, points: [[Double]]) {
            self.couleur = couleur; self.epaisseur = epaisseur; self.points = points
        }
    }
    public var largeur: Double
    public var hauteur: Double
    public var traits: [Stroke]
    public init(largeur: Double, hauteur: Double, traits: [Stroke]) {
        self.largeur = largeur; self.hauteur = hauteur; self.traits = traits
    }
    /// Schéma fermé à la frontière d'import : JSONDecoder seul ignorerait les clés inconnues.
    init?(validated value: AnnotationImport.JSONValue) {
        guard case let .object(fields) = value,
              Set(fields.keys) == Set(["largeur", "hauteur", "traits"]),
              case let .array(strokes) = fields["traits"],
              strokes.allSatisfy({ stroke in
                  guard case let .object(fields) = stroke else { return false }
                  return Set(fields.keys) == Set(["couleur", "epaisseur", "points"])
              }),
              let data = try? JSONEncoder().encode(value),
              let drawing = try? JSONDecoder().decode(Self.self, from: data), drawing.isValid
        else { return nil }
        self = drawing
    }
    public var isValid: Bool {
        guard largeur.isFinite, hauteur.isFinite, (100...4096).contains(largeur),
              (100...4096).contains(hauteur), (1...128).contains(traits.count),
              traits.reduce(0, { $0 + $1.points.count }) <= 12_000 else { return false }
        return traits.allSatisfy { t in
            ["klein", "redon", "noir"].contains(t.couleur) && t.epaisseur.isFinite
                && (0.001...0.05).contains(t.epaisseur) && (1...4096).contains(t.points.count)
                && t.points.allSatisfy { $0.count == 3 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }
        }
    }
    public var strokesJSON: String? {
        guard isValid else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(traits)).map { String(decoding: $0, as: UTF8.self) }
    }
    public var svg: String? {
        guard isValid else { return nil }
        let palette = ["klein": "#002FA7", "redon": "#A33A32", "noir": "#000000"]
        var elements: [String] = []
        for t in traits {
            let color = palette[t.couleur]!
            for i in t.points.indices {
                let p = t.points[i], q = t.points[max(0, i - 1)]
                let width = t.epaisseur * min(largeur, hauteur) * (0.25 + 0.75 * (p[2] + q[2]) / 2)
                if i == 0 {
                    elements.append("<circle cx=\"\(p[0] * largeur)\" cy=\"\(p[1] * hauteur)\" r=\"\(width / 2)\" fill=\"\(color)\"/>")
                } else {
                    elements.append("<path d=\"M \(q[0] * largeur) \(q[1] * hauteur) L \(p[0] * largeur) \(p[1] * hauteur)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(width)\" stroke-linecap=\"round\"/>")
                }
            }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(largeur) \(hauteur)\" width=\"\(largeur)\" height=\"\(hauteur)\">" + elements.joined() + "</svg>"
    }
}
