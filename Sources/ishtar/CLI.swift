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
                      Embed.self, Find.self, OCRCompare.self, ImportBibtex.self, ImportZotero.self,
                      Keys.self, Publish.self, Typographie.self, Regrouper.self]
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

        if !report.isComplete || report.hasScanErrors {
            print("\n⚠️ SCAN INCOMPLET : \(report.errorMessage ?? "Erreur d'accès pendant le parcours")")
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
        if report.isScanIncomplete {
            print("⚠️ SCAN INCOMPLET : \(report.scanErrorMessage ?? "Erreur lors du scan")")
            print("Aucune modification apportée au catalogue.")
            return
        }
        print("Documents scannés   \(report.scanned)")
        print("  ajoutés           \(report.added)")
        print("  conservés         \(report.kept)")
        print("  introuvables      \(report.missing)")
        print("  retrouvés         \(report.recovered)")
        print("  déplacés          \(report.relocated)")
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

// MARK: - Import BibTeX (WP-10 / M2b — le pendant en entrée de l'export WP-09)

struct ImportBibtex: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-bibtex",
        abstract: "Importe et rapproche un fichier BibTeX (ex: Zotero) avec les documents existants."
    )

    @Argument(help: "Le fichier BibTeX à importer.", transform: URL.init(fileURLWithPath:))
    var file: URL

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Applique les propositions sûres à la base de données. Par défaut, n'applique rien (simulation).")
    var apply = false

    func run() async throws {
        let content = try String(contentsOf: file, encoding: .utf8)
        let entries = BibTeXParser.parse(content: content)
        
        print("Fichier lu : \(file.lastPathComponent)")
        print("Entrées trouvées : \(entries.count)")
        print("Recherche des correspondances dans le catalogue...")
        
        let database = try CatalogDatabase(at: db)
        let importer = BibTeXImporter()
        let report = try await importer.match(entries: entries, in: database)
        
        print(String(repeating: "─", count: 60))
        print("Documents lus           \(report.totalRead)")
        print("Rapprochements sûrs     \(report.strongMatches.count) (fichier, DOI, ISBN)")
        print("Rapprochements faibles  \(report.weakMatches.count) (titre + auteur)")
        print("Sans correspondance     \(report.unmatched.count)")
        
        if apply {
            print(String(repeating: "─", count: 60))
            print("Application des propositions sûres...")
            var applied = 0
            // Un rapprochement sûr peut viser un document qui n'a pas encore
            // d'édition. On ne peut pas lui appliquer la notice — applyProposal
            // écrit sur l'œuvre que porte l'édition — mais on ne l'escamote pas
            // pour autant : il est compté et nommé. Rien ne disparaît en silence.
            var skipped: [String] = []

            for match in report.strongMatches {
                guard let doc = match.document, let guess = match.guess else { continue }
                guard let editionId = doc.editionId,
                      let edition = try await database.pool.read({ try Edition.fetchOne($0, key: editionId) })
                else {
                    skipped.append(doc.originalFileName)
                    continue
                }

                let authors = guess.author?.components(separatedBy: " and ") ?? []

                try await CatalogStore(db: database).applyProposal(
                    workId: edition.workId,
                    editionId: doc.editionId,
                    documentId: doc.id,
                    title: guess.title,
                    authors: authors,
                    year: guess.year,
                    publisher: guess.publisher,
                    language: guess.language,
                    isbn13: guess.isbn13,
                    doi: guess.doi
                )
                applied += 1
            }
            
            print("\(applied) document(s) mis à jour de façon certaine.")
            if !skipped.isEmpty {
                print("\(skipped.count) rapprochement(s) sûr(s) NON appliqué(s) — document sans édition :")
                for name in skipped.prefix(10) { print("  · \(name)") }
                if skipped.count > 10 { print("  … et \(skipped.count - 10) autre(s)") }
            }
            if !report.weakMatches.isEmpty {
                print("Note : \(report.weakMatches.count) propositions faibles ont été ignorées. Elles devront être validées manuellement (non pris en charge par le CLI).")
            }
        } else {
            print(String(repeating: "─", count: 60))
            print("Mode simulation. Utilisez --apply pour écrire les propositions sûres.")
        }
    }
}

// MARK: - Import Zotero (WP-10 / M2b)

struct ImportZotero: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-zotero",
        abstract: "Importe et rapproche les collections depuis une base Zotero."
    )

    @Argument(help: "Le fichier zotero.sqlite ou son dossier parent à importer.", transform: URL.init(fileURLWithPath:))
    var path: URL

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Applique les propositions à la base de données. Par défaut, n'applique rien (simulation).")
    var apply = false

    func run() async throws {
        print("Fichier / dossier lu : \(path.lastPathComponent)")
        print("Recherche des correspondances dans le catalogue...")
        
        let database = try CatalogDatabase(at: db)
        let importer = ZoteroImporter()
        let report = try await importer.importDatabase(at: path, into: database, apply: apply)
        
        print(String(repeating: "─", count: 60))
        print("Items lus                   \(report.itemsRead)")
        print("Pièces jointes trouvées     \(report.attachmentsFound)")
        print("Pièces rapprochées          \(report.matchedAttachments)")
        for (reason, count) in report.matchReasons {
            print("  - signal : \(reason) (\(count))")
        }
        print("Collections à créer         \(report.collectionsCreated)")
        print("Items sans fichier chez ns  \(report.itemsWithoutFile)")
        print("Non classables (ss édition) \(report.unclassifiableDocuments)")
        
        if apply {
            print(String(repeating: "─", count: 60))
            print("Application terminée avec succès.")
        } else {
            print(String(repeating: "─", count: 60))
            print("Mode simulation. Utilisez --apply pour écrire les collections.")
        }
    }
}

// MARK: - Clés de citation et publication (lots F2, F3)

struct Keys: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attribue une clé de citation à chaque édition qui n'en a pas (les clés existantes ne changent jamais)."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Affiche toutes les clés après attribution.")
    var list = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let assigned = try await CatalogStore(db: database).assignMissingKeys()
        print("Clés attribuées : \(assigned)")
        if list {
            let keys = try await database.pool.read {
                try String.fetchAll($0, sql: "SELECT key FROM edition_key ORDER BY key COLLATE NOCASE")
            }
            keys.forEach { print($0) }
        }
    }
}

struct Publish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Publie le catalogue : catalogue.json, couvertures et base réduite, lisibles sans Ishtar."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Option(name: .long, help: "Racine de la bibliothèque (les chemins publiés lui sont relatifs).")
    var root: String

    @Option(name: .long, help: "Dossier de publication.", transform: URL.init(fileURLWithPath:))
    var out: URL

    @Option(name: .long, help: "Dossier des vignettes d'Ishtar (<sha256>.png), copiées comme couvertures.",
            transform: URL.init(fileURLWithPath:))
    var covers: URL?

    @Option(name: .long, help: "Dossier (relatif à la racine) à ne jamais publier. Répétable.")
    var exclude: [String] = []

    @Option(name: .long, help: "Préfixe de titre à ne pas publier. Répétable.")
    var excludeTitlePrefix: [String] = []

    @Flag(name: .long, help: "Fabrique les couvertures absentes du dossier de vignettes (QuickLook, 1re page).")
    var renderCovers = false

    @Flag(name: .long, help: "Joint la base réduite (textes intégraux, volumineuse).")
    var withDatabase = false

    @Flag(name: .long, help: "Construit et résume sans rien écrire.")
    var dryRun = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        // Un catalogue antérieur à la v7 n'a pas encore de clés.
        try await CatalogStore(db: database).assignMissingKeys()
        let rules = PublicationRules(excludedFolders: exclude, excludedTitlePrefixes: excludeTitlePrefix)
        let publisher = CatalogPublisher(db: database)

        let report: PublicationReport
        if dryRun {
            report = try await publisher.build(root: root, rules: rules).1
        } else {
            let render: (@Sendable (URL) async -> Data?)? = renderCovers
                ? { @Sendable url in await CoverRenderer.png(for: url, strictness: 0.5) } : nil
            report = try await publisher.publish(root: root, rules: rules, to: out, coversFolder: covers,
                                                 includeDatabase: withDatabase, renderCover: render)
        }
        print(dryRun ? "Publication (essai à blanc)" : "Publié dans \(out.path)")
        print(String(repeating: "─", count: 60))
        print("Éditions publiées        \(report.editions)")
        print("Fichiers                 \(report.files)")
        print("Couvertures              \(report.covers)")
        print("Écartés par les règles   \(report.excludedByRule)")
        print("Introuvables ou ignorés  \(report.excludedMissingOrIgnored)")
    }
}

// MARK: - Restauration typographique

struct Typographie: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rend aux titres et aux auteurs la graphie que portent les fichiers (accents, apostrophes), sans jamais changer de titre."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Écrit les corrections (sinon : seulement les montrer).")
    var appliquer = false

    @Option(name: .long, help: "Nombre d'exemples à afficher.")
    var exemples = 25

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let proposals = try await TypographyPass.proposals(in: database)
        let titres = proposals.filter { $0.newTitle != nil }.count
        let auteurs = proposals.filter { $0.newAuthor != nil }.count
        print("Propositions : \(proposals.count) œuvres — \(titres) titres, \(auteurs) auteurs")
        print(String(repeating: "─", count: 60))
        for p in proposals.prefix(exemples) {
            if let t = p.newTitle { print("titre   \(p.oldTitle)  →  \(t)") }
            if let a = p.newAuthor { print("auteur  \(p.oldAuthor ?? "")  →  \(a)") }
        }
        if appliquer {
            let n = try await TypographyPass.apply(proposals, to: database)
            print(String(repeating: "─", count: 60))
            print("Appliqué à \(n) œuvres.")
        }
    }
}

// MARK: - Regroupement des éditions

struct Regrouper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Réunit sous une seule fiche et une seule clé le même livre en plusieurs fichiers (même auteur, titre, année)."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Écrit les regroupements (sinon : seulement les montrer).")
    var appliquer = false

    @Option(name: .long, help: "Nombre d'exemples à afficher.")
    var exemples = 30

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let groups = try await EditionGrouping.proposals(in: database)
        let absorbed = groups.reduce(0) { $0 + $1.absorbedEditionIds.count }
        print("Groupes : \(groups.count) — \(absorbed) éditions à absorber")
        print(String(repeating: "─", count: 60))
        for g in groups.prefix(exemples) {
            print("\(g.keptKey ?? "?")  ×\(g.absorbedEditionIds.count + 1)  \(g.author ?? "") — \(g.title) (\(g.year ?? "s.d."))")
        }
        if appliquer {
            let n = try await EditionGrouping.apply(groups, to: database)
            print(String(repeating: "─", count: 60))
            print("\(n) éditions absorbées.")
        }
    }
}
