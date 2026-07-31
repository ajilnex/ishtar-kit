import ArgumentParser
import Foundation
import IshtarCatalog
import IshtarIngest
import IshtarSearch
import PDFKit

@main
struct IshtarCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ishtar",
        abstract: "Ishtar — le moteur de bibliothèque savante. / The scholarly library engine.",
        version: "0.2.0",
        subcommands: [Scan.self, Ingest.self, Extract.self, Search.self,
                      Embed.self, Find.self, OCRCompare.self]
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

// MARK: - Banc de mesure OCR (WP-OCR-MESURE)

/// Compare les deux moteurs Vision sur un même PDF muet, sans rien écrire dans
/// un catalogue : le moteur macOS 26 (`RecognizeDocumentsRequest`) et le repli
/// (`VNRecognizeTextRequest`). Le but n'est pas le nombre de caractères mais le
/// MODE d'échec (renoncer vs inventer), qui se lit dans les transcriptions.
/// Arbitre la règle anti-OCR-génératif (voir ../docs/30-CHANTIERS.md, bloc OCR).
struct OCRCompare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr-compare",
        abstract: "Compare les deux moteurs OCR Vision sur un PDF muet (macOS 26 vs repli) et écrit les transcriptions à comparer à l'œil."
    )

    @Argument(help: "Le PDF (scanné/muet) à reconnaître.", transform: URL.init(fileURLWithPath:))
    var pdf: URL

    @Option(name: .long, help: "Première page à traiter (1-indexée, défaut 1).")
    var from: Int = 1

    @Option(name: .long, help: "Nombre de pages à traiter (défaut 3).")
    var pages: Int = 3

    @Option(name: .long, help: "Dossier de sortie des transcriptions (défaut : ./ocr-compare).",
            transform: URL.init(fileURLWithPath:))
    var out: URL = URL(fileURLWithPath: "ocr-compare")

    func run() async throws {
        guard let doc = PDFDocument(url: pdf) else {
            throw ValidationError("PDF illisible : \(pdf.path)")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let start = max(0, from - 1)
        let end = min(start + pages, doc.pageCount)
        print("Comparaison OCR — \(pdf.lastPathComponent) — pages \(start + 1)…\(end) sur \(doc.pageCount)")
        print("Sortie : \(out.path)")
        print(String(repeating: "─", count: 64))
        print("page │  macOS 26 (car.) │  repli (car.) │ écart")

        for index in start ..< end {
            guard let page = doc.page(at: index),
                  let image = OCRExtractor.renderPage(page) else { continue }

            let modern: String
            do {
                modern = try await OCRExtractor.recognize(in: image, engine: .documentRequest)
            } catch OCRExtractor.OCRError.engineUnavailable(let why) {
                modern = "‹moteur macOS 26+ indisponible : \(why)›"
            }
            let legacy = try await OCRExtractor.recognize(in: image, engine: .legacyText)

            let number = index + 1
            try modern.write(to: out.appendingPathComponent("p\(number)-macos26.txt"),
                             atomically: true, encoding: .utf8)
            try legacy.write(to: out.appendingPathComponent("p\(number)-legacy.txt"),
                             atomically: true, encoding: .utf8)

            print(String(format: "%4d │ %16d │ %13d │ %+d",
                         number, modern.count, legacy.count, modern.count - legacy.count))
        }

        print(String(repeating: "─", count: 64))
        print("Lis les fichiers p*-macos26.txt et p*-legacy.txt : le nombre de")
        print("caractères ne dit rien du mode d'échec. Cherche les endroits où un")
        print("moteur invente un mot plausible là où l'autre laisse un trou.")
    }
}
