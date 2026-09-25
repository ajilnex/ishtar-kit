import ArgumentParser
import Foundation
import GRDB
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
                      Keys.self, Publish.self, Typographie.self, Regrouper.self, Autorites.self, Reidentifier.self, Langues.self, Traductions.self, Ranger.self, Verifier.self, Corriger.self, Auteurs.self, Titres.self, Prenoms.self, Doublons.self]
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

    @Flag(name: .long, help: "Recalcule les clés provisoires avec les règles du moment (jamais les clés figées ou manuelles).")
    var recalculer = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        if recalculer {
            let changed = try await CatalogStore(db: database).recomputeProvisionalKeys()
            print("Clés provisoires recalculées : \(changed) ont changé")
        }
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

    @Option(name: .long, help: "Identifiant court du fonds (provenance), par exemple « aj ».")
    var fonds: String?

    @Option(name: .long, help: "Nom sous lequel le fonds se présente (défaut : son identifiant).")
    var fondsNom: String?

    @Flag(name: .long, help: "Fabrique les couvertures absentes du dossier de vignettes (QuickLook, 1re page).")
    var renderCovers = false

    @Flag(name: .long, help: "Publie le corpus pour les modèles de langage (corpus/<sha256>.pages.deflate).")
    var corpus = false

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
        let provenance = fonds.map { PublishedFonds(id: $0, nom: fondsNom ?? $0) }

        let report: PublicationReport
        if dryRun {
            report = try await publisher.build(root: root, rules: rules, fonds: provenance).1
        } else {
            let render: (@Sendable (URL) async -> Data?)? = renderCovers
                ? { @Sendable url in await CoverRenderer.png(for: url, strictness: 0.5) } : nil
            report = try await publisher.publish(root: root, rules: rules, to: out, coversFolder: covers,
                                                 includeDatabase: withDatabase, includeCorpus: corpus,
                                                 fonds: provenance, renderCover: render)
        }
        print(dryRun ? "Publication (essai à blanc)"
              : report.unchanged ? "Rien de changé : \(out.path) est à jour" : "Publié dans \(out.path)")
        print(String(repeating: "─", count: 60))
        print("Éditions publiées        \(report.editions)")
        print("Fichiers                 \(report.files)")
        print("Couvertures              \(report.covers)")
        if corpus { print("Corpus (écrits)          \(report.corpusWritten)") }
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
        let sousTitres = proposals.filter { $0.newSubtitle != nil }.count
        print("Propositions : \(proposals.count) œuvres — \(titres) titres, \(sousTitres) sous-titres, \(auteurs) auteurs")
        print(String(repeating: "─", count: 60))
        for p in proposals.prefix(exemples) {
            if let t = p.newTitle { print("titre   \(p.oldTitle)  →  \(t)") }
            if let st = p.newSubtitle { print("sous-t. \(p.newTitle ?? p.oldTitle)  +  \(st)") }
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
        let works = try await EditionGrouping.workProposals(in: database)
        print(String(repeating: "─", count: 60))
        print("Œuvres à plusieurs éditions : \(works.count)")
        for w in works.prefix(exemples) {
            print("\(w.title)  ×\(w.absorbed.count + 1)  (\(w.years.joined(separator: ", ")))")
        }
        if appliquer {
            let n = try await EditionGrouping.apply(groups, to: database)
            let m = try await EditionGrouping.applyWorks(works, to: database)
            print(String(repeating: "─", count: 60))
            print("\(n) éditions absorbées, \(m) œuvres réunies.")
        }
    }
}

// MARK: - Autorités

struct Autorites: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Relie les auteurs à leurs notices d'autorité (IdRef, BnF, VIAF, ISNI, Wikidata). Réseau : geste volontaire."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Écrit les liens (sinon : seulement les montrer).")
    var appliquer = false

    @Option(name: .long, help: "N'examiner que les N premiers auteurs en attente.")
    var limite: Int?

    @Flag(name: .long, help: "Met les noms des auteurs reliés à la forme de leur autorité (usage + classement) ; fusionne les doublons de personne.")
    var noms = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let outcomes = try await AuthorityPass.run(in: database, apply: appliquer, limit: limite) { o in
            switch o.decision {
            case let .confirmed(c, evidence): print("✓ \(o.name)  →  \(c.label) [\(c.ppn)] — \(evidence)")
            case let .proposed(cs, evidence): print("? \(o.name)  →  \(cs.map { "\($0.label) [\($0.ppn)]" }.joined(separator: " | ")) — \(evidence)")
            case .notFound: print("· \(o.name)")
            }
        }
        let confirmed = outcomes.filter { if case .confirmed = $0.decision { true } else { false } }.count
        let proposed = outcomes.filter { if case .proposed = $0.decision { true } else { false } }.count
        print(String(repeating: "─", count: 60))
        print("\(outcomes.count) auteurs examinés : \(confirmed) confirmés, \(proposed) à valider, \(outcomes.count - confirmed - proposed) introuvables.")
        if noms {
            let names = try await AuthorityNames.proposals(in: database)
            print(String(repeating: "─", count: 60))
            print("Noms à la forme de leur autorité : \(names.count)")
            for n in names { print("\(n.current)  →  \(n.name)   [\(n.sortName)]") }
            if appliquer {
                try await AuthorityNames.apply(names, to: database)
                print("Appliqué.")
            }
        }
    }
}

// MARK: - Réidentification

struct Reidentifier: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Relit noms de fichiers et métadonnées avec les règles d'aujourd'hui ; départage les auteurs contradictoires par le Sudoc (--sudoc)."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Écrit les relectures (et les conflits tranchés, avec --sudoc).")
    var appliquer = false

    @Flag(name: .long, help: "Interroge le Sudoc pour départager les conflits d'attribution (réseau).")
    var sudoc = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let (proposals, conflicts) = try await Reidentification.examine(in: database)
        print("Relectures : \(proposals.count)")
        print(String(repeating: "─", count: 60))
        for p in proposals {
            print("\(p.fileName) — \(p.current.author ?? "∅") — \(p.current.title) (\(p.current.year ?? "s.d."))")
            if let t = p.title { print("   titre   → \(t)") }
            if let d = p.workDate { print("   année   → \(d) (œuvre)") }
            if let a = p.authorForAnonymous { print("   auteur  → \(a)") }
            if let r = p.renamedAuthor { print("   nom     → \(r.to)") }
        }
        var settled = conflicts
        if sudoc { settled = await Reidentification.settle(conflicts) }
        print(String(repeating: "─", count: 60))
        print("Conflits d'attribution : \(settled.count)")
        for c in settled {
            let verdict: String
            switch c.resolution {
            case .enrich(let n): verdict = "nom complet → \(n)"
            case .replace(let n): verdict = "autre auteur → \(n)"
            case .split(let ns): verdict = "co-auteurs → \(ns.joined(separator: " ; "))"
            case .undecided: verdict = "INDÉCIS"
            }
            print("\(c.fileName)\n   fiche « \(c.catalogAuthor) » · fichier « \(c.fileAuthor ?? "∅") » · métadonnées « \(c.embeddedAuthor ?? "∅") »\n   \(verdict)\(c.settledBySudoc ? " (Sudoc)" : "")")
        }
        if appliquer {
            let n = try await Reidentification.apply(proposals, to: database)
            let m = try await Reidentification.apply(attributions: settled, to: database)
            print(String(repeating: "─", count: 60))
            print("\(n) relectures appliquées, \(m) attributions corrigées.")
        }
    }
}

// MARK: - Langues

struct Langues: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Reconnaît la langue des éditions sur leur texte (local, sans réseau)."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Écrit les langues (sinon : seulement les montrer).")
    var appliquer = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let proposals = try await LanguagePass.proposals(in: database)
        let counts = Dictionary(grouping: proposals, by: \.language).mapValues(\.count).sorted { $0.value > $1.value }
        print("Langues reconnues : \(proposals.count) — " + counts.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        if appliquer {
            try await LanguagePass.apply(proposals, to: database)
            print("Appliqué.")
        }
    }
}

// MARK: - Traductions

struct Traductions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Relie originaux et traductions possédés sous une même œuvre (Wikidata ; auteurs reliés). Réseau."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Écrit les rattachements (sinon : seulement les montrer).")
    var appliquer = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        var links: [AuthorityLink] = []
        let groups = try await TranslationPass.proposals(in: database, links: &links)
        print("Œuvres reconnues dans Wikidata : \(links.count) — réunions : \(groups.count)")
        print(String(repeating: "─", count: 60))
        for g in groups {
            print("\(g.originalTitle ?? g.label) (\(g.originalLanguage ?? "?"), \(g.year ?? "s.d.")) [\(g.qid)]")
            for w in g.works { print("   \(w.title)  \(w.languages.joined(separator: ","))") }
        }
        if appliquer {
            let n = try await TranslationPass.apply(groups, links: links, to: database)
            print(String(repeating: "─", count: 60))
            print("\(n) œuvres réunies à leur original ou à leurs sœurs.")
        }
    }
}

// MARK: - Ranger (bibliothèque confiée)

struct Ranger: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Renomme les fichiers d'après leur fiche : « Adorno — Minima moralia (1951).pdf ». Journal pour défaire."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Option(name: .long, help: "Racine de la bibliothèque.")
    var racine: String

    @Option(name: .long, help: "Dossier à laisser tel quel (répétable) : espaces de travail, mangas…")
    var exclure: [String] = []

    @Option(name: .long, help: "Ne renommer que les N premiers (essai).")
    var limite: Int?

    @Flag(name: .long, help: "Renomme (sinon : seulement montrer).")
    var appliquer = false

    @Option(name: .long, help: "Journal des renommages (TSV : ancien, nouveau).")
    var journal: String = "\(NSHomeDirectory())/Library/Logs/ishtar-ranger.tsv"

    @Option(name: .long, help: "Défait les renommages de ce journal (du dernier au premier).")
    var defaire: String?

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let store = CatalogStore(db: database)
        if let defaire {
            let lines = try String(contentsOfFile: defaire, encoding: .utf8).split(separator: "\n").reversed()
            var n = 0
            for line in lines {
                let f = line.split(separator: "\t").map(String.init)
                guard f.count == 3, let id = UUID(uuidString: f[0]) else { continue }
                if try await store.perform(Renaming(documentId: id, from: f[2], to: f[1])) { n += 1 }
            }
            print("\(n) renommages défaits.")
            return
        }
        var plan = try await store.arrangement(root: racine, excludedFolders: Set(exclure))
        // Gardes : un nom de fichier qui désigne un autre auteur que la fiche
        // est un conflit non résolu (le nom de fichier est un témoin : on ne
        // l'efface pas) ; les fiches « TRIER » attendent Aubin.
        var held: [(Renaming, String)] = []
        plan = plan.filter { r in
            let target = (r.to as NSString).lastPathComponent
            if target.contains("TRIER") { held.append((r, "à trier")); return false }
            if let t = FilenameParser.parse(fileName: target).title as String?,
               ["unknown", "untitled", "inconnu", "sanstitre"].contains(t.lowercased().filter(\.isLetter)) {
                held.append((r, "titre inconnu")); return false
            }
            if r.verified { return true }
            let old = FilenameParser.parse(fileName: (r.from as NSString).lastPathComponent)
            let new = FilenameParser.parse(fileName: target)
            if old.confidence == .structured, let a = old.author, let b = new.author, !Reidentification.isPlaceholder(a),
               Reidentification.family(a) != Reidentification.family(b.components(separatedBy: " & ").first ?? b)
                && !Reidentification.sameAuthor(a, b)
                // Co-auteurs joints : « Badiou-Roudinesco » devient « Badiou & Roudinesco ».
                && Reidentification.family(a.components(separatedBy: "-").first) != Reidentification.family(b.components(separatedBy: " & ").first ?? b) {
                held.append((r, "le nom de fichier dit « \(a) »")); return false
            }
            return true
        }
        if let limite { plan = Array(plan.prefix(limite)) }
        if !held.isEmpty {
            print("Laissés tels quels : \(held.count)")
            for (r, why) in held.prefix(appliquer ? held.count : 20) { print("   \((r.from as NSString).lastPathComponent) — \(why)") }
        }
        print("Renommages : \(plan.count)")
        for r in plan.prefix(appliquer ? plan.count : 40) {
            print("\((r.from as NSString).lastPathComponent)\n   → \((r.to as NSString).lastPathComponent)")
        }
        guard appliquer else { return }
        // Le journal s'allonge, il n'est jamais écrasé : chaque ligne défait un geste.
        if !FileManager.default.fileExists(atPath: journal) { FileManager.default.createFile(atPath: journal, contents: nil) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: journal))
        try handle.seekToEnd()
        var done = 0
        for r in plan {
            if try await store.perform(r) {
                try handle.write(contentsOf: Data("\(r.documentId.uuidString)\t\(r.from)\t\(r.to)\n".utf8))
                done += 1
            }
        }
        try handle.close()
        print("\(done) fichiers renommés. Journal : \(journal)")
    }
}

// MARK: - Vérifier par le contenu

struct Verifier: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Confronte chaque fiche aux premières pages du livre : fiches étrangères, tomes, jumeaux."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Affiche l'ouverture de chaque livre suspect.")
    var ouvertures = false

    @Option(name: .long, help: "Dossier dont les jumeaux sont voulus (répétable) : espaces de travail, traductions en cours…")
    var exclure: [String] = []

    @Flag(name: .long, help: "Réunit les jumeaux sous la fiche que le texte confirme le mieux.")
    var appliquer = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        var (findings, twins) = try await ContentCheck.examine(in: database)
        twins = twins.filter { t in !t.paths.contains { p in exclure.contains { p.contains("/\($0)/") } } }
        print("Fiches que le livre dément : \(findings.count) — jumeaux : \(twins.count)")
        print(String(repeating: "─", count: 60))
        for f in findings.sorted(by: { $0.fileName < $1.fileName }) {
            print("[\(f.kind == .volumeMismatch ? "tome" : "étrangère")] \(f.fileName) — \(f.author ?? "∅") — \(f.title) (\(f.pageCount) p.)")
            if ouvertures { print("   « \(f.opening) »") }
        }
        print(String(repeating: "─", count: 60))
        for t in twins { print("jumeaux : " + t.titles.joined(separator: "  =  ") + "   → garder « \(t.titles[t.best]) »") }
        if appliquer {
            let n = try await ContentCheck.merge(twins, in: database)
            print("\(n) éditions réunies à leur jumelle.")
        }
    }
}

// MARK: - Corrections vérifiées sur pièce

struct Corriger: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Applique des corrections vérifiées sur la page de titre (JSON) : la fiche passe en confiance haute, avec sa note de provenance."
    )

    struct Correction: Decodable {
        let fichier: String
        /// Vrai : ce n'est pas un livre (papier personnel, rapport, note) —
        /// le fichier rejoint `_NON_BIBLIO/`, à côté de lui ; rien d'autre.
        let nonBiblio: Bool?
        /// Vrai : le fichier a été rattaché à tort à une autre œuvre ; il
        /// reçoit d'abord une fiche à lui, puis la correction.
        let detacher: Bool?
        let titre: String?
        let auteurs: [String]?
        let annee: String?
        let edition: String?
        let editeur: String?
        let isbn: String?
        let langue: String?
        let preuve: String?
    }

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Option(name: .long, help: "Fichier JSON des corrections.")
    var fichier: String

    @Option(name: .long, help: "Qui corrige (pour la note de provenance).")
    var par: String = "Claude, à la demande d'Aubin"

    @Flag(name: .long, help: "Écrit les corrections (sinon : seulement vérifier qu'on trouve chaque fichier).")
    var appliquer = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let store = CatalogStore(db: database)
        let corrections = try JSONDecoder().decode([Correction].self, from: Data(contentsOf: URL(fileURLWithPath: fichier)))
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        var done = 0
        for c in corrections {
            if c.detacher == true, appliquer, let first = try await store.document(named: c.fichier) {
                try await store.detach(documentId: first.documentId)
            }
            guard let target = try await store.document(named: c.fichier) else {
                print("introuvable ou ambigu : \(c.fichier)"); continue
            }
            if c.nonBiblio == true {
                print("\(c.fichier)\n   → _NON_BIBLIO")
                guard appliquer, let path = try await store.path(ofDocument: target.documentId) else { continue }
                let dir = (path as NSString).deletingLastPathComponent
                let destination = ((dir as NSString).appendingPathComponent("_NON_BIBLIO") as NSString)
                    .appendingPathComponent((path as NSString).lastPathComponent)
                try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                let move = Renaming(documentId: target.documentId, from: path, to: destination)
                if try await store.perform(move) {
                    let journal = "\(NSHomeDirectory())/Library/Logs/ishtar-ranger.tsv"
                    if !FileManager.default.fileExists(atPath: journal) { FileManager.default.createFile(atPath: journal, contents: nil) }
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: journal))
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("\(move.documentId.uuidString)\t\(move.from)\t\(move.to)\n".utf8))
                    try handle.close()
                    done += 1
                }
                continue
            }
            guard let titre = c.titre, let auteurs = c.auteurs else { print("   titre ou auteurs manquants"); continue }
            print("\(c.fichier)\n   → \(auteurs.joined(separator: " ; ")) — \(titre) (\(c.annee ?? "s.d."))")
            guard appliquer else { continue }
            try await store.applyUserEdit(workId: target.workId, editionId: target.editionId, documentId: target.documentId,
                                          edit: RecordEdit(title: titre, authors: auteurs, year: c.edition ?? c.annee,
                                                           publisher: c.editeur, language: c.langue, isbn13: c.isbn))
            let note = "Vérifié sur pièce le \(day) (\(par))" + (c.preuve.map { " : \($0)" } ?? ".")
            try await store.annotateWork(target.workId, date: c.annee, note: note)
            done += 1
        }
        if appliquer { print("\(done) fiches corrigées.") }
    }
}

// MARK: - Noms d'auteur (renommer, séparer)

struct Auteurs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Renomme ou sépare des fiches de personne d'après un fichier JSON : [{\"de\": \"Van-Fraassen\", \"vers\": [\"Bas C. van Fraassen\"]}]."
    )

    /// `tri` : la forme de classement, quand l'autorité se trompe de nom de
    /// famille (« Viveiros de Castro, Eduardo »).
    struct Entry: Decodable { let de: String; let vers: [String]; let tri: String? }

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Option(name: .long, help: "Fichier JSON.")
    var fichier: String

    @Flag(name: .long, help: "Écrit (sinon : seulement vérifier).")
    var appliquer = false

    func run() async throws {
        let store = CatalogStore(db: try CatalogDatabase(at: db))
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: fichier)))
        for e in entries {
            guard let id = try await store.creatorId(named: e.de) else { print("introuvable : \(e.de)"); continue }
            print("\(e.de)  →  \(e.vers.joined(separator: " ; "))")
            guard appliquer else { continue }
            if e.vers.count == 1 {
                let kept = try await store.renameCreator(id, to: e.vers[0])
                if let tri = e.tri { try await store.setSortName(tri, forCreator: kept) }
            }
            else { try await store.splitCreator(named: e.de, into: e.vers) }
        }
    }
}

// MARK: - Titres (graphie du Sudoc)

struct Titres: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rend aux titres privés d'accents et d'apostrophes la graphie du Sudoc (même titre seulement). Réseau."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Écrit (sinon : seulement montrer).")
    var appliquer = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let list = try await TitlePass.proposals(in: database)
        print("Titres rendus à leur graphie : \(list.count)")
        for r in list { print("\(r.current)  →  \(r.restored)") }
        if appliquer { print("Appliqué à \(try await TitlePass.apply(list, to: database)) œuvres.") }
    }
}

// MARK: - Prénoms (Sudoc)

struct Prenoms: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rend leur prénom aux auteurs réduits à leur nom, d'après la notice Sudoc d'un de leurs livres. Réseau."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Flag(name: .long, help: "Écrit (sinon : seulement montrer).")
    var appliquer = false

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let list = try await GivenNamePass.proposals(in: database)
        print("Prénoms retrouvés : \(list.count)")
        for n in list { print("\(n.current)  →  \(n.name)   — \(n.evidence)") }
        if appliquer { try await GivenNamePass.apply(list, to: database); print("Appliqué.") }
    }
}

// MARK: - Doublons d'un même fonds

struct Doublons: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Deux fichiers de même format pour une même édition : garde l'annoté (sinon le plus gros), range les autres dans _NON_BIBLIO/_doublons (journal défaisable)."
    )

    @Option(name: .long, help: "Chemin du fichier catalogue SQLite.", transform: URL.init(fileURLWithPath:))
    var db: URL

    @Option(name: .long, help: "Racine de la bibliothèque.")
    var racine: String

    @Option(name: .long, help: "Dossier laissé tel quel (répétable).")
    var exclure: [String] = []

    @Flag(name: .long, help: "Déplace (sinon : seulement montrer).")
    var appliquer = false

    /// Annotations d'un PDF faites par un lecteur (surlignages, notes), hors liens et champs.
    static func annotations(_ path: String) -> Int {
        guard path.lowercased().hasSuffix(".pdf"), let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return 0 }
        var n = 0
        for i in 0..<min(doc.pageCount, 2000) {
            n += doc.page(at: i)?.annotations.filter { !["Link", "Widget"].contains($0.type ?? "") }.count ?? 0
        }
        return n
    }

    func run() async throws {
        let database = try CatalogDatabase(at: db)
        let store = CatalogStore(db: database)
        let root = URL(fileURLWithPath: racine).standardizedFileURL.path
        let rows = try await database.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT d.id AS id, d.editionId AS editionId, d.filePath AS path, d.format AS format, d.fileSize AS size
                FROM document d WHERE d.isMissing = 0 AND d.editionId IS NOT NULL
                """)
        }
        var groups: [String: [(id: UUID, path: String, size: Int)]] = [:]
        for r in rows {
            let path: String = r["path"]
            guard path.hasPrefix(root + "/") else { continue }
            let rel = String(path.dropFirst(root.count + 1))
            if rel.split(separator: "/").dropLast().contains(where: { exclure.contains(String($0)) }) { continue }
            let key = "\(r["editionId"] as UUID)|\(r["format"] as String)"
            groups[key, default: []].append((r["id"], path, r["size"]))
        }
        var moved = 0
        for (_, files) in groups.sorted(by: { $0.key < $1.key }) where files.count > 1 {
            let ranked = files.map { f in (f, Self.annotations(f.path)) }
                .sorted { ($0.1, $0.0.size) > ($1.1, $1.0.size) }
            let kept = ranked[0]
            print("garde  \((kept.0.path as NSString).lastPathComponent)\(kept.1 > 0 ? "  (\(kept.1) annotations)" : "")")
            for (f, notes) in ranked.dropFirst() {
                print("  range \((f.path as NSString).lastPathComponent)\(notes > 0 ? "  (\(notes) annotations — gardé aussi)" : "")")
                // Un exemplaire annoté n'est jamais écarté, même s'il y en a un autre plus annoté.
                guard appliquer, notes == 0 else { continue }
                let dest = ((root as NSString).appendingPathComponent("_NON_BIBLIO/_doublons") as NSString)
                    .appendingPathComponent((f.path as NSString).lastPathComponent)
                try FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let move = Renaming(documentId: f.id, from: f.path, to: dest)
                if try await store.perform(move) {
                    let journal = "\(NSHomeDirectory())/Library/Logs/ishtar-ranger.tsv"
                    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: journal))
                    try h.seekToEnd(); try h.write(contentsOf: Data("\(move.documentId.uuidString)\t\(move.from)\t\(move.to)\n".utf8)); try h.close()
                    moved += 1
                }
            }
        }
        if appliquer { print("\(moved) doublons rangés dans _NON_BIBLIO/_doublons.") }
    }
}
