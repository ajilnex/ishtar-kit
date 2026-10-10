import ArgumentParser
import Foundation
import GRDB
import IshtarCatalog

struct CollectionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "collection",
        abstract: "Réunit des œuvres existantes dans une collection, sans copier les fichiers.")
    @Option(name: .long, transform: URL.init(fileURLWithPath:)) var db: URL
    @Option(name: .long) var nom: String
    @Option(name: .long, help: "Fichier JSON contenant les clés d'édition.") var cles: String
    @Flag(name: .long) var appliquer = false

    func run() async throws {
        let keys = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: cles)))
        let database = try CatalogDatabase(at: db)
        let id = try await CollectionStore(db: database).add(keys: keys, to: nom, apply: appliquer)
        print("\(appliquer ? "Collection retenue" : "Simulation") : \(nom), \(keys.count) clés\(id.map { " — " + $0.uuidString } ?? "")")
    }
}


/// Rattachement borné d'un nouvel exemplaire à une édition déjà identifiée.
struct Rattacher: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rattache un exemplaire à une édition identique, sur preuve, sans modifier ses octets ni ses annotations.")
    @Option(name: .long, transform: URL.init(fileURLWithPath:)) var db: URL
    @Option(name: .long) var fichier: String
    @Option(name: .long) var a: String
    @Option(name: .long) var preuve: String
    @Flag(name: .long) var appliquer = false

    func run() async throws {
        guard !preuve.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("Preuve requise.") }
        let database = try CatalogDatabase(at: db)
        let store = CatalogStore(db: database)
        guard let source = try await store.document(named: fichier) else { throw ValidationError("Fichier introuvable ou ambigu.") }
        let cible = try await database.pool.read { conn in
            try UUID.fetchOne(conn, sql: """
                SELECT d.id FROM document d JOIN edition_key k ON k.editionId = d.editionId
                WHERE k.key = ? COLLATE NOCASE AND d.isMissing = 0 ORDER BY d.dateAdded, d.id LIMIT 1
                """, arguments: [a])
        }
        guard let cible else { throw ValidationError("Édition cible introuvable.") }
        print("\(fichier) → \(a) : \(preuve)")
        if appliquer {
            try await store.merge(duplicates: [source.documentId], into: cible, humanConfirmed: false)
        }
    }
}
