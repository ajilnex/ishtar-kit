import Foundation
import IshtarCatalog
import GRDB

/// Type de signal de rapprochement (fort ou faible)
public enum MatchSignal: Equatable, Sendable {
    case strong(reason: String)
    case weak(reason: String)
    case none
}

/// Résultat du rapprochement pour une entrée BibTeX
public struct BibTeXMatch: Sendable {
    public let entry: BibTeXEntry
    public let document: Document?
    public let signal: MatchSignal
    public let guess: MetadataGuess?
    
    public init(entry: BibTeXEntry, document: Document?, signal: MatchSignal, guess: MetadataGuess?) {
        self.entry = entry
        self.document = document
        self.signal = signal
        self.guess = guess
    }
}

/// Rapport complet de l'import
public struct BibTeXImportReport: Sendable {
    public let totalRead: Int
    public let matches: [BibTeXMatch]
    
    public var strongMatches: [BibTeXMatch] { matches.filter { if case .strong = $0.signal { return true } else { return false } } }
    public var weakMatches: [BibTeXMatch] { matches.filter { if case .weak = $0.signal { return true } else { return false } } }
    public var unmatched: [BibTeXMatch] { matches.filter { if case .none = $0.signal { return true } else { return false } } }
}

/// Rapproche les entrées BibTeX des documents du catalogue.
public struct BibTeXImporter: Sendable {
    
    public init() {}
    
    public func match(entries: [BibTeXEntry], in db: CatalogDatabase) async throws -> BibTeXImportReport {
        let results: [BibTeXMatch] = try await db.pool.read { conn in
            var localResults: [BibTeXMatch] = []
            let allDocuments = try Document.fetchAll(conn)
            let allEditions = try Edition.fetchAll(conn)
            let allWorks = try Work.fetchAll(conn)
            
            for entry in entries {
                let match = matchSingle(entry: entry, documents: allDocuments, editions: allEditions, works: allWorks, in: conn)
                localResults.append(match)
            }
            return localResults
        }
        
        return BibTeXImportReport(totalRead: entries.count, matches: results)
    }
    
    private func matchSingle(entry: BibTeXEntry, documents: [Document], editions: [Edition], works: [Work], in db: GRDB.Database) -> BibTeXMatch {
        let title = entry.fields["title"] ?? "Sans titre"
        let rawAuthors = entry.fields["author"]
        var year = entry.fields["year"]
        if year == nil, let date = entry.fields["date"], date.count >= 4 {
            year = String(date.prefix(4))
        }
        let publisher = entry.fields["publisher"]
        let language = entry.fields["language"]
        let doi = entry.fields["doi"]
        let isbn13 = entry.fields["isbn"]
        
        let authors = rawAuthors.map { BibTeXParser.normalizeAuthors($0).joined(separator: " and ") }
        
        let guess = MetadataGuess(
            title: title,
            author: authors,
            year: year,
            publisher: publisher,
            language: language,
            isbn13: isbn13,
            doi: doi,
            confidence: .structured // Ce sera affiné lors de l'applyProposal, l'importateur produit structuré car les champs sont nets
        )
        
        // 1. Fichier exact (champ 'file')
        if let fileField = entry.fields["file"] {
            // Format Zotero/Better BibTeX : description:chemin:type
            let parts = fileField.components(separatedBy: ";")
            for part in parts {
                let segments = part.components(separatedBy: ":")
                if segments.count >= 2 {
                    let path = segments[1]
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    
                    if let doc = documents.first(where: { $0.originalFileName == fileName }) {
                        return BibTeXMatch(entry: entry, document: doc, signal: .strong(reason: "fichier exact (\(fileName))"), guess: guess)
                    }
                }
            }
        }
        
        // 2. DOI ou ISBN exact
        if let doi = doi, !doi.isEmpty {
            if let edition = editions.first(where: { $0.doi == doi }),
               let doc = documents.first(where: { $0.editionId == edition.id }) {
                return BibTeXMatch(entry: entry, document: doc, signal: .strong(reason: "DOI exact"), guess: guess)
            }
        }
        
        if let isbn = isbn13, !isbn.isEmpty {
            let normalizedISBN = isbn.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            if let edition = editions.first(where: { $0.isbn13?.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "") == normalizedISBN }),
               let doc = documents.first(where: { $0.editionId == edition.id }) {
                return BibTeXMatch(entry: entry, document: doc, signal: .strong(reason: "ISBN exact"), guess: guess)
            }
        }
        
        // 3. Signal faible : Titre + Auteur
        if let entryAuthors = rawAuthors, !entryAuthors.isEmpty {
            let normalizedTitle = title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            
            for work in works {
                let workTitleNorm = work.title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
                if workTitleNorm == normalizedTitle {
                    // Vérifier l'auteur
                    if let creators = try? Creator.fetchAll(db, sql: "SELECT creator.* FROM creator JOIN work_creator ON creator.id = work_creator.creatorId WHERE work_creator.workId = ?", arguments: [work.id]) {
                        
                        let entryNormAuthors = BibTeXParser.normalizeAuthors(entryAuthors).map { $0.folding(options: .diacriticInsensitive, locale: .current).lowercased() }
                        let workNormAuthors = creators.map { $0.name.folding(options: .diacriticInsensitive, locale: .current).lowercased() }
                        
                        // Intersection
                        let intersection = Set(entryNormAuthors).intersection(Set(workNormAuthors))
                        if !intersection.isEmpty {
                            if let edition = editions.first(where: { $0.workId == work.id }),
                               let doc = documents.first(where: { $0.editionId == edition.id }) {
                                return BibTeXMatch(entry: entry, document: doc, signal: .weak(reason: "titre et auteur"), guess: guess)
                            }
                        }
                    }
                }
            }
        }
        
        return BibTeXMatch(entry: entry, document: nil, signal: .none, guess: nil)
    }
}
