import ArgumentParser
import Foundation
import IshtarCatalog

/// Fusion de deux éditions à clés figées (là où `regrouper` et `rattacher` s'arrêtent).
struct Fusionner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fusionne une édition dans une autre : documents et annotations suivent, l'ancienne clé devient une pierre qui renvoie à la gardée.",
        discussion: """
            Sans --appliquer : essai à blanc, rien n'est écrit. Avec --appliquer : Ishtar doit être \
            fermée ; ecriture.verrou est posé puis levé, une seule transaction, refus si une annotation \
            serait perdue.
            """
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Option(name: .long, help: "La clé de l'édition absorbée (elle devient une pierre).")
    var cle: String

    @Option(name: .long, help: "La clé de l'édition gardée.")
    var dans: String

    @Option(name: .long, help: "Ce qui prouve que c'est la même édition ; inscrit dans la raison de la pierre.")
    var preuve: String?

    @Flag(name: .long, help: "Écrit la fusion (sinon : essai à blanc).")
    var appliquer = false

    func run() async throws {
        guard FileManager.default.fileExists(atPath: db.path) else {
            throw ValidationError("Catalogue introuvable : \(db.path)")
        }
        // Avant d'ouvrir la base : sinon le contrôle des fichiers ouverts nous verrait nous-mêmes.
        var jeton: EcritureVerrou.Jeton?
        if appliquer {
            jeton = try EcritureVerrou.poser(pour: db, qui: "ishtar fusionner",
                                             pourquoi: "fusion \(cle) → \(dans)")
        } else if let obstacle = EcritureVerrou.obstacle(pour: db) {
            print("Attention (bloquerait --appliquer) : \(obstacle)")
        }
        var reussi = false
        defer { if reussi || !appliquer { jeton?.liberer() } }
        do {
            let database = try CatalogDatabase(at: db)
            let r = try await CatalogStore(db: database).mergeEditions(
                absorbedKey: cle, into: dans, preuve: preuve, apply: appliquer)
            print("\(appliquer ? "Fusion faite" : "Essai à blanc (rien d'écrit)") : \(r.absorbedKey) → \(r.keptKey)")
            for d in r.documents { print("  document déplacé : \(d.fileName) (\(d.annotations) annotation(s))") }
            print("  \(r.documents.count) document(s), \(r.annotationsKept) annotation(s) conservée(s), aucune perdue")
            print("  pierre : \(r.absorbedKey) → \(r.keptKey) (« \(EditionFusion.raison) »), \(r.stonesRedirected) pierre(s) redirigée(s)")
            if r.contributorsCarried > 0 { print("  \(r.contributorsCarried) contributeur(s) de l'édition reporté(s)") }
            if r.demotedPreferred > 0 { print("  \(r.demotedPreferred) préféré(s) de l'absorbée rétrogradé(s) : le préféré de \(r.keptKey) reste préféré") }
            if r.keptKeyFrozen { print("  la clé \(r.keptKey) était provisoire : elle est figée") }
            print("  édition retirée : \(r.absorbedKey)" + (r.workRemoved.map { " ; œuvre retirée : « \($0) »" } ?? ""))
            if !appliquer { print("Rien d'écrit (ajouter --appliquer, Ishtar fermée).") }
            reussi = true
        } catch let refus as EditionFusion.Refus {
            reussi = true  // rien n'a été écrit : le verrou se lève
            print(refus.localizedDescription)
            throw ExitCode.failure
        }
    }
}
