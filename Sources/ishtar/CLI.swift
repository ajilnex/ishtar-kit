import ArgumentParser
import Foundation
import IshtarCatalog
import IshtarIngest
import IshtarSearch

@main
struct IshtarCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ishtar",
        abstract: "Ishtar — le moteur de bibliothèque savante. / The scholarly library engine.",
        version: "0.2.0",
        subcommands: [Scan.self, Ingest.self, Extract.self, Search.self,
                      Embed.self, Find.self]
    )
}

struct Embed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Vectorise localement les pages extraites (index sémantique, rien ne sort de la machine)."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let store = try EmbeddingStore(at: EmbeddingStore.url(forCatalog: db))
        let embeddings = try LocalEmbeddings()
        let indexer = SemanticIndexer(db: database, store: store, embeddings: embeddings)

        print("Modèle local : \(embeddings.modelID) (dimension \(embeddings.dimension))")
        let done = try await indexer.indexAllPending { done, total in
            print("\rVectorisation \(done)/\(total)…", terminator: "")
            fflush(stdout)
        }
        print("\n\(done) page(s) vectorisée(s). Index : \(try store.count()) vecteurs.")
    }
}

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Recherche hybride (plein texte + sémantique) : décrire vaguement suffit."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Argument(help: "La description ou les termes du passage cherché.")
    var query: [String]

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let store = try EmbeddingStore(at: EmbeddingStore.url(forCatalog: db))
        let embeddings = try LocalEmbeddings()
        try await embeddings.ensureAssets()
        let search = SemanticSearch(db: database, store: store, embeddings: embeddings)

        let hits = try await search.search(query.joined(separator: " "), limit: 12)
        guard !hits.isEmpty else {
            print("Aucun passage trouvé.")
            return
        }
        for hit in hits {
            let authors = hit.authors.isEmpty ? "" : " — \(hit.authors.joined(separator: ", "))"
            print("« \(hit.title) »\(authors) [p. \(hit.pageNumber)]")
            print("   \(hit.excerpt.replacingOccurrences(of: "\n", with: " "))\n")
        }
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scanne un dossier sans rien modifier et rapporte ce qui s'y trouve."
    )

    @Argument(help: "Le dossier à scanner.", transform: URL.init(fileURLWithPath:))
    var directory: URL

    @Flag(name: .long, help: "Ne pas calculer les empreintes SHA-256 (plus rapide, pas de détection de doublons).")
    var skipHashes = false

    func run() async throws {
        let start = Date()
        let report = LibraryScanner(computeHashes: !skipHashes).scan(directory: directory)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))

        print("Scan de \(directory.path)")
        print(String(repeating: "─", count: 60))

        var byFormat: [DocumentFormat: Int] = [:]
        for file in report.files { byFormat[file.format, default: 0] += 1 }

        var structured = 0
        for file in report.files where FilenameParser.parse(fileName: file.fileName).confidence == .structured {
            structured += 1
        }

        print("Documents reconnus     \(report.files.count)")
        for (format, count) in byFormat.sorted(by: { $0.value > $1.value }) {
            print("  \(format.rawValue.uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)) \(count)")
        }
        print("Nom de fichier lisible \(structured) / \(report.files.count)")
        print("Doublons de contenu    \(report.duplicateGroups.count) groupe(s)")
        print("Fichiers non gérés     \(report.unsupportedCount)")
        print("Durée                  \(elapsed) s")

        if !report.duplicateGroups.isEmpty {
            print("\nDoublons détectés (contenu identique) :")
            for group in report.duplicateGroups {
                for file in group { print("  · \(file.fileName)") }
                print("")
            }
        }
    }
}

struct Ingest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scanne un dossier et construit (ou met à jour) un catalogue SQLite."
    )

    @Argument(help: "Le dossier source.", transform: URL.init(fileURLWithPath:))
    var directory: URL

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let scanReport = LibraryScanner().scan(directory: directory)
        let report = try Ingestor().ingest(report: scanReport, sourceFolder: directory, into: database)

        print("Catalogue : \(db.path)")
        print(String(repeating: "─", count: 60))
        print("Documents scannés   \(report.scanned)")
        print("  ajoutés           \(report.added)")
        print("  conservés         \(report.kept)")
        print("  retirés           \(report.removed)")
        print("  reconnus          \(report.recognized)")
        print("  à identifier      \(report.needsReview)")
        print("  doublons          \(report.duplicates)")
        print("Collections créées  \(report.collectionsCreated)")
        print("Fichiers non gérés  \(report.unsupported)")
    }
}

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extrait le texte des documents et alimente l'index plein texte (FTS5)."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    func run() async throws {
        let database = try CatalogDatabase(at: db)

        print("Extraction du texte : \(db.path)")
        print(String(repeating: "─", count: 60))

        let processed = try await ExtractionPipeline().extractAllPending(into: database) { done, total in
            // Progression réécrite sur la même ligne (stderr), sobre.
            let pct = total == 0 ? 100 : done * 100 / total
            FileHandle.standardError.write(Data("\r  \(done)/\(total) (\(pct) %)".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))

        print("Documents extraits  \(processed)")
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Cherche un passage dans le texte plein des documents (FTS5, bm25)."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Argument(help: "Les termes à chercher.")
    var terms: [String]

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let query = terms.joined(separator: " ")
        let hits = try await FulltextSearch(db: database).search(query)

        print("Recherche « \(query) » : \(hits.count) passage(s)")
        print(String(repeating: "─", count: 60))
        for hit in hits {
            let authors = hit.authors.isEmpty ? "" : " — " + hit.authors.joined(separator: ", ")
            print("\(hit.title)\(authors)  [p. \(hit.pageNumber)]")
            print("  \(hit.snippet)")
        }
    }
}
