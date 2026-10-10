import Foundation
import ArgumentParser
import GRDB
import IshtarCatalog

struct AnnotationsImporter: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotations-importer",
        abstract: "Importe une file Rayons de notes et surlignements. Sans --appliquer, simule puis annule le lot."
    )
    @Option(name: .long, help: "Catalogue SQLite existant (migration v11 requise).", transform: URL.init(fileURLWithPath:))
    var db: URL
    @Option(name: .long, help: "Fonds attendu, obligatoire et identique au lot.")
    var fonds: String
    @Option(name: .long, help: "Fichier JSON exporté par Rayons.", transform: URL.init(fileURLWithPath:))
    var ops: URL
    @Flag(name: .long, help: "Valide la transaction ; sinon annule toutes les écritures.")
    var appliquer = false

    func run() async throws {
        guard FileManager.default.fileExists(atPath: db.path) else { throw ValidationError("Catalogue absent.") }
        let batch = try JSONDecoder().decode(AnnotationImport.Batch.self, from: Data(contentsOf: ops))
        // Pas de CatalogDatabase(at:) : l'import ne crée ni ne migre un catalogue.
        let pool = try DatabasePool(path: db.path)
        let report = try await AnnotationImport().importer(batch, fonds: fonds, in: pool, appliquer: appliquer)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
