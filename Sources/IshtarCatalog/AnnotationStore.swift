import Foundation
import GRDB

/// Les surlignements : création, note, couleur, suppression, lecture. Rien
/// d'autre — la résolution d'ancrage vit à côté (`AnnotationAnchor`),
/// l'interface au-dessus.
public struct AnnotationStore: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    @discardableResult
    public func add(_ annotation: Annotation) async throws -> Annotation {
        try await db.pool.write { conn in
            try annotation.insert(conn)
        }
        return annotation
    }

    public func updateNote(id: UUID, note: String?) async throws {
        try await db.pool.write { conn in
            guard var annotation = try Annotation.fetchOne(conn, key: id) else { return }
            annotation.note = note
            annotation.dateModified = Date()
            try annotation.update(conn)
        }
    }

    public func setColor(id: UUID, color: String?) async throws {
        try await db.pool.write { conn in
            guard var annotation = try Annotation.fetchOne(conn, key: id) else { return }
            annotation.color = color
            annotation.dateModified = Date()
            try annotation.update(conn)
        }
    }

    public func remove(id: UUID) async throws {
        _ = try await db.pool.write { conn in
            try Annotation.deleteOne(conn, key: id)
        }
    }

    /// Les surlignements d'un document, dans l'ordre de lecture (page puis
    /// date de création — les EPUB, sans page, suivent la date).
    public func annotations(documentId: UUID) async throws -> [Annotation] {
        try await db.pool.read { conn in
            try Annotation
                .filter(Column("documentId") == documentId)
                .fetchAll(conn)
                .sorted {
                    switch ($0.pageNumber, $1.pageNumber) {
                    case let (a?, b?) where a != b: return a < b
                    case (nil, _?): return false
                    case (_?, nil): return true
                    default: return $0.dateCreated < $1.dateCreated
                    }
                }
        }
    }

    public func count() async throws -> Int {
        try await db.pool.read { try Annotation.fetchCount($0) }
    }

    /// Filtre et classe purement en mémoire les résultats de recherche.
    public static func search(query: String, in candidates: [AnnotationSearchResult]) -> [AnnotationSearchResult] {
        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if normalizedQuery.isEmpty { return [] }
        
        return candidates.compactMap { candidate -> (result: AnnotationSearchResult, isNoteMatch: Bool, isQuoteMatch: Bool)? in
            let note = candidate.annotation.note ?? ""
            let quote = candidate.annotation.quote
            let normNote = note.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let normQuote = quote.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            
            let isNoteMatch = normNote.contains(normalizedQuery)
            let isQuoteMatch = normQuote.contains(normalizedQuery)
            
            if isNoteMatch || isQuoteMatch {
                return (candidate, isNoteMatch, isQuoteMatch)
            }
            return nil
        }
        .sorted { a, b in
            if a.isNoteMatch != b.isNoteMatch {
                return a.isNoteMatch // priorise la note
            }
            if a.isQuoteMatch != b.isQuoteMatch {
                return a.isQuoteMatch // puis la citation
            }
            // puis date de modif la plus récente
            return a.result.annotation.dateModified > b.result.annotation.dateModified
        }
        .map { $0.result }
    }

    /// Recherche les annotations (note ou quote) qui matchent la requête.
    public func search(query: String, documentId: UUID? = nil) async throws -> [AnnotationSearchResult] {
        let candidates = try await db.pool.read { conn -> [AnnotationSearchResult] in
            var req = Annotation.all()
            if let documentId {
                req = req.filter(Column("documentId") == documentId)
            }
            let annotations = try req.fetchAll(conn)
            if annotations.isEmpty { return [] }
            
            let documentIds = Array(Set(annotations.map(\.documentId)))
            let documents = try Document.fetchAll(conn, keys: documentIds)
            let editionIds = Array(Set(documents.compactMap(\.editionId)))
            let editions = try Edition.fetchAll(conn, keys: editionIds)
            let workIds = Array(Set(editions.map(\.workId)))
            let works = try Work.fetchAll(conn, keys: workIds)
            
            let workCreators = try WorkCreator
                .filter(workIds.contains(Column("workId")))
                .order(Column("position"))
                .fetchAll(conn)
            
            let creatorIds = Array(Set(workCreators.map(\.creatorId)))
            let creators = try Creator.fetchAll(conn, keys: creatorIds)
            
            let creatorById = Dictionary(uniqueKeysWithValues: creators.map { ($0.id, $0) })
            var authorsByWork: [UUID: [String]] = [:]
            for wc in workCreators where wc.role == .author {
                if let creator = creatorById[wc.creatorId] {
                    authorsByWork[wc.workId, default: []].append(creator.name)
                }
            }
            
            let workById = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
            let editionById = Dictionary(uniqueKeysWithValues: editions.map { ($0.id, $0) })
            let documentById = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
            
            return annotations.compactMap { annotation in
                guard let document = documentById[annotation.documentId],
                      let editionId = document.editionId,
                      let edition = editionById[editionId],
                      let work = workById[edition.workId] else {
                    return nil
                }
                return AnnotationSearchResult(
                    annotation: annotation,
                    workTitle: work.title,
                    authors: authorsByWork[work.id] ?? []
                )
            }
        }
        
        return Self.search(query: query, in: candidates)
    }
}

/// Résultat de recherche d'une annotation avec son contexte bibliographique.
public struct AnnotationSearchResult: Sendable, Equatable {
    public let annotation: Annotation
    public let workTitle: String
    public let authors: [String]

    public init(annotation: Annotation, workTitle: String, authors: [String]) {
        self.annotation = annotation
        self.workTitle = workTitle
        self.authors = authors
    }
}
