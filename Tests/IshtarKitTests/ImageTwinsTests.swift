// Propre à macOS (rendu de page par Core Graphics) : hors de la suite Linux (WP-34).
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import Testing
@testable import IshtarIngest

/// Deux scans du même livre sans texte : le 16/11/2026, deux copies du même
/// manuel (l'une réexportée en A4, avec des surlignements) portaient chacune
/// sa fiche, faute de texte à comparer.
@Suite("Jumeaux d'image — deux scans du même livre")
struct ImageTwinsTests {

    /// Un « scan » inventé : sur chaque page, des bandes grises dont la place
    /// et la noirceur dépendent de `graine` et du numéro de page. `taille`
    /// change la page sans changer ce qu'elle montre ; `surligne` ajoute un
    /// aplat clair sur une page sur cinq, comme le ferait un lecteur.
    private func scan(pages: Int, graine: Int, taille: CGSize = CGSize(width: 554, height: 720),
                      surligne: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jumeaux-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: taille)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for n in 0..<pages {
            context.beginPDFPage(nil)
            // Une page sur sept presque blanche, une sur onze très chargée : le profil d'encre du livre.
            let bandes = (n + graine) % 7 == 0 ? 1 : ((n + graine) % 11 == 0 ? 14 : 4 + (n * 31 + graine * 17) % 6)
            for b in 0..<bandes {
                let y = taille.height * CGFloat((b * 53 + n * 29 + graine * 13) % 90) / 100
                let w = taille.width * CGFloat(40 + (b * 37 + n * 11 + graine) % 55) / 100
                context.setFillColor(gray: CGFloat((b * 7 + n + graine) % 5) / 10, alpha: 1)
                context.fill(CGRect(x: taille.width * 0.05, y: y, width: w, height: taille.height * 0.04))
            }
            if surligne, n % 5 == 0 {
                context.setFillColor(red: 1, green: 0.95, blue: 0.3, alpha: 0.4)
                context.fill(CGRect(x: taille.width * 0.1, y: taille.height * 0.5, width: taille.width * 0.6, height: taille.height * 0.03))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    @Test("Le même livre réexporté dans une autre taille, surligné : jumeaux")
    func memeLivreReexporte() throws {
        let a = try scan(pages: 60, graine: 3)
        let b = try scan(pages: 60, graine: 3, taille: CGSize(width: 595, height: 842), surligne: true)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(ImageTwins.find(among: [(id: "a", url: a), (id: "b", url: b)]) == [["a", "b"]])
    }

    @Test("Deux livres différents de même nombre de pages et de même taille : pas jumeaux")
    func livresDifferents() throws {
        let a = try scan(pages: 60, graine: 3)
        let b = try scan(pages: 60, graine: 8)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(ImageTwins.find(among: [(id: "a", url: a), (id: "b", url: b)]).isEmpty)
    }

    @Test("Un nombre de pages différent, ou un fichier trop court : rien")
    func pagesDifferentes() throws {
        let a = try scan(pages: 60, graine: 3)
        let b = try scan(pages: 61, graine: 3)
        let court1 = try scan(pages: 6, graine: 3), court2 = try scan(pages: 6, graine: 3)
        defer { for u in [a, b, court1, court2] { try? FileManager.default.removeItem(at: u) } }
        #expect(ImageTwins.find(among: [(id: 1, url: a), (id: 2, url: b), (id: 3, url: court1), (id: 4, url: court2)]).isEmpty)
    }

    @Test("Trois exemplaires et un intrus : un seul groupe de trois")
    func troisExemplaires() throws {
        let urls = [try scan(pages: 40, graine: 5), try scan(pages: 40, graine: 5, surligne: true),
                    try scan(pages: 40, graine: 9), try scan(pages: 40, graine: 5, taille: CGSize(width: 420, height: 595))]
        defer { for u in urls { try? FileManager.default.removeItem(at: u) } }
        let groupes = ImageTwins.find(among: urls.indices.map { (id: $0, url: urls[$0]) })
        #expect(groupes.map { $0.sorted() } == [[0, 1, 3]])
    }

    @Test("Les pages témoins : réparties, bornées, hors des couvertures")
    func temoins() {
        #expect(ImageTwins.witnesses(count: 5).isEmpty)
        let t = ImageTwins.witnesses(count: 372)
        #expect(t.count == ImageTwins.maximumWitnesses)
        #expect(t.first == 3 && t.last == 370)
        #expect(t == t.sorted() && Set(t).count == t.count)
        #expect(ImageTwins.witnesses(count: 12) == Array(3...10))
    }

    @Test("La corrélation : 1 pour deux suites proportionnelles, 0 pour une suite plate")
    func correlation() {
        #expect(abs(ImageTwins.correlation([1, 2, 3, 4], [10, 20, 30, 40]) - 1) < 1e-9)
        #expect(abs(ImageTwins.correlation([1, 2, 3, 4], [4, 3, 2, 1]) + 1) < 1e-9)
        #expect(ImageTwins.correlation([1, 2, 3], [5, 5, 5]) == 0)
        #expect(ImageTwins.correlation([1, 2], [1]) == 0)
    }
}
#endif
