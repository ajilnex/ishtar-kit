import ArgumentParser
import Foundation
import IshtarCatalog
import IshtarIngest

@main
struct IshtarCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ishtar",
        abstract: "Ishtar — le moteur de bibliothèque savante. / The scholarly library engine.",
        version: "0.1.0 (M0)",
        subcommands: [Scan.self, Ingest.self]
    )
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
