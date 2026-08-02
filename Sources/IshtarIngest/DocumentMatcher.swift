import Foundation
import IshtarCatalog
import GRDB

public struct MatchQuery: Sendable {
    public var title: String?
    public var rawAuthors: String?
    public var year: String?
    public var publisher: String?
    public var language: String?
    public var doi: String?
    public var isbn13: String?
    public var fileNames: [String]
    
    public init(title: String? = nil, rawAuthors: String? = nil, year: String? = nil, publisher: String? = nil, language: String? = nil, doi: String? = nil, isbn13: String? = nil, fileNames: [String] = []) {
        self.title = title
        self.rawAuthors = rawAuthors
        self.year = year
        self.publisher = publisher
        self.language = language
        self.doi = doi
        self.isbn13 = isbn13
        self.fileNames = fileNames
    }
}

public struct DocumentMatch: Sendable {
    public let document: Document?
    public let signal: MatchSignal
    public let guess: MetadataGuess?
    
    public init(document: Document?, signal: MatchSignal, guess: MetadataGuess?) {
        self.document = document
        self.signal = signal
        self.guess = guess
    }
}

public struct DocumentMatcher: Sendable {
    
    public init() {}
    
    public func match(query: MatchQuery, documents: [Document], editions: [Edition], works: [Work], in db: GRDB.Database) -> DocumentMatch {
        var guess: MetadataGuess? = nil
        
        if let title = query.title {
            let authors = query.rawAuthors.map { BibTeXParser.normalizeAuthors($0).joined(separator: " and ") }
            guess = MetadataGuess(
                title: title,
                author: authors,
                year: query.year,
                publisher: query.publisher,
                language: query.language,
                isbn13: query.isbn13,
                doi: query.doi,
                confidence: .structured
            )
        }
        
        // 1. Fichier exact
        for path in query.fileNames {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            if let doc = documents.first(where: { $0.originalFileName == fileName }) {
                return DocumentMatch(document: doc, signal: .strong(reason: "fichier exact (\(fileName))"), guess: guess)
            }
        }
        
        // 2. DOI ou ISBN exact
        if let doi = query.doi, !doi.isEmpty {
            if let edition = editions.first(where: { $0.doi == doi }),
               let doc = documents.first(where: { $0.editionId == edition.id }) {
                return DocumentMatch(document: doc, signal: .strong(reason: "DOI exact"), guess: guess)
            }
        }
        
        if let isbn = query.isbn13, !isbn.isEmpty {
            let normalizedISBN = isbn.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            if let edition = editions.first(where: { $0.isbn13?.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "") == normalizedISBN }),
               let doc = documents.first(where: { $0.editionId == edition.id }) {
                return DocumentMatch(document: doc, signal: .strong(reason: "ISBN exact"), guess: guess)
            }
        }
        
        // 3. Signal faible : Titre + Auteur
        if let title = query.title, let rawAuthors = query.rawAuthors, !rawAuthors.isEmpty {
            let normalizedTitle = title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            
            for work in works {
                let workTitleNorm = work.title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
                if workTitleNorm == normalizedTitle {
                    if let creators = try? Creator.fetchAll(db, sql: "SELECT creator.* FROM creator JOIN work_creator ON creator.id = work_creator.creatorId WHERE work_creator.workId = ?", arguments: [work.id]) {
                        
                        let entryNormAuthors = BibTeXParser.normalizeAuthors(rawAuthors).map { $0.folding(options: .diacriticInsensitive, locale: .current).lowercased() }
                        let workNormAuthors = creators.map { $0.name.folding(options: .diacriticInsensitive, locale: .current).lowercased() }
                        
                        let intersection = Set(entryNormAuthors).intersection(Set(workNormAuthors))
                        if !intersection.isEmpty {
                            if let edition = editions.first(where: { $0.workId == work.id }),
                               let doc = documents.first(where: { $0.editionId == edition.id }) {
                                return DocumentMatch(document: doc, signal: .weak(reason: "titre et auteur"), guess: guess)
                            }
                        }
                    }
                }
            }
        }
        
        return DocumentMatch(document: nil, signal: .none, guess: nil)
    }
}
