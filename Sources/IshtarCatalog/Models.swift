import Foundation
import GRDB

// MARK: - Vocabulaire de curation
//
// Ishtar doit pouvoir dire « je sais », « je crois », « j'ai besoin d'aide ».
// Ces états s'appliquent aux œuvres, aux éditions et aux documents.

public enum CurationStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case recognized
    case needsReview
    case duplicateCandidate
    case ignored
}

public enum Confidence: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case high
    case probable
    case low
}

public enum DocumentFormat: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case pdf, epub, mobi, azw3, djvu, txt, md, docx, rtf

    public init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }
}

public enum CreatorRole: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case author
    case translator
    case editor
    case prefacer
    case director
}

// MARK: - Ontologie FRBR-légère : Œuvre / Édition / Document

/// L'œuvre intellectuelle. « Kant, Critique de la raison pure. »
public struct Work: Identifiable, Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "work"

    public var id: UUID
    public var title: String
    public var subtitle: String?
    public var originalLanguage: String?
    /// Date de composition ou de première publication (texte libre : "1781", "IVe s. av. J.-C.").
    public var date: String?
    public var discipline: String?
    public var notes: String?
    public var curationStatus: CurationStatus
    public var confidence: Confidence

    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        originalLanguage: String? = nil,
        date: String? = nil,
        discipline: String? = nil,
        notes: String? = nil,
        curationStatus: CurationStatus = .needsReview,
        confidence: Confidence = .low
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.originalLanguage = originalLanguage
        self.date = date
        self.discipline = discipline
        self.notes = notes
        self.curationStatus = curationStatus
        self.confidence = confidence
    }
}

/// Une manifestation de l'œuvre. « Trad. Tremesaygues & Pacaud, PUF, 1944. »
public struct Edition: Identifiable, Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "edition"

    public var id: UUID
    public var workId: UUID
    /// Titre porté par cette édition s'il diffère de celui de l'œuvre.
    public var title: String?
    public var publisher: String?
    public var year: String?
    public var language: String?
    public var isbn13: String?
    public var doi: String?
    public var curationStatus: CurationStatus
    public var confidence: Confidence

    public init(
        id: UUID = UUID(),
        workId: UUID,
        title: String? = nil,
        publisher: String? = nil,
        year: String? = nil,
        language: String? = nil,
        isbn13: String? = nil,
        doi: String? = nil,
        curationStatus: CurationStatus = .needsReview,
        confidence: Confidence = .low
    ) {
        self.id = id
        self.workId = workId
        self.title = title
        self.publisher = publisher
        self.year = year
        self.language = language
        self.isbn13 = isbn13
        self.doi = doi
        self.curationStatus = curationStatus
        self.confidence = confidence
    }
}

/// Un fichier concret. Le dossier source n'est jamais modifié ; Ishtar ne fait que l'observer.
public struct Document: Identifiable, Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "document"

    public var id: UUID
    public var editionId: UUID?
    public var filePath: String
    public var originalFileName: String
    public var fileSize: Int64
    /// SHA-256 du contenu — clef de la déduplication.
    public var contentHash: String?
    public var format: DocumentFormat
    public var dateAdded: Date
    public var needsOCR: Bool
    public var isTextExtracted: Bool
    public var curationStatus: CurationStatus
    public var confidence: Confidence

    public init(
        id: UUID = UUID(),
        editionId: UUID? = nil,
        filePath: String,
        originalFileName: String,
        fileSize: Int64,
        contentHash: String? = nil,
        format: DocumentFormat,
        dateAdded: Date = Date(),
        needsOCR: Bool = false,
        isTextExtracted: Bool = false,
        curationStatus: CurationStatus = .needsReview,
        confidence: Confidence = .low
    ) {
        self.id = id
        self.editionId = editionId
        self.filePath = filePath
        self.originalFileName = originalFileName
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.format = format
        self.dateAdded = dateAdded
        self.needsOCR = needsOCR
        self.isTextExtracted = isTextExtracted
        self.curationStatus = curationStatus
        self.confidence = confidence
    }
}

/// Une page de texte extraite d'un document, unité d'indexation plein texte.
/// Le fichier source n'est jamais modifié : ces pages vivent dans la base.
/// L'extraction est idempotente (les pages d'un document sont remplacées en bloc).
public struct DocumentPage: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "document_page"

    public var documentId: UUID
    /// Numéro de page (1-based). Pour les PDF, la page réelle ; pour les autres
    /// formats, un compteur séquentiel sur l'ordre de lecture.
    public var pageNumber: Int
    public var content: String

    public init(documentId: UUID, pageNumber: Int, content: String) {
        self.documentId = documentId
        self.pageNumber = pageNumber
        self.content = content
    }
}

// MARK: - Surlignements

/// Un surlignement PERSISTANT de l'utilisateur (≠ surbrillance éphémère —
/// Vocabulaire). Ancré par le TEXTE : la citation exacte fait foi, la page ou
/// le CFI ne sont que des accélérateurs de résolution.
public struct Annotation: Identifiable, Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "annotation"

    public var id: UUID
    public var documentId: UUID
    /// Page mémorisée (PDF / pages extraites) ; nil pour un EPUB.
    public var pageNumber: Int?
    /// Position CFI dans l'EPUB ; nil pour un PDF.
    public var cfi: String?
    /// La citation exacte : c'est elle qui ancre le surlignement.
    public var quote: String
    /// Contexte avant/après la citation, pour départager les occurrences.
    public var prefix: String?
    public var suffix: String?
    public var note: String?
    public var color: String?
    /// Couche par Projet (réservé, nil en v1).
    public var projectId: UUID?
    public var dateCreated: Date
    public var dateModified: Date

    public init(
        id: UUID = UUID(),
        documentId: UUID,
        pageNumber: Int? = nil,
        cfi: String? = nil,
        quote: String,
        prefix: String? = nil,
        suffix: String? = nil,
        note: String? = nil,
        color: String? = nil,
        projectId: UUID? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.documentId = documentId
        self.pageNumber = pageNumber
        self.cfi = cfi
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.note = note
        self.color = color
        self.projectId = projectId
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }
}

// MARK: - Personnes et attributions

public struct Creator: Identifiable, Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "creator"

    public var id: UUID
    public var name: String
    /// Forme de tri : « Kant, Immanuel ».
    public var sortName: String?

    public init(id: UUID = UUID(), name: String, sortName: String? = nil) {
        self.id = id
        self.name = name
        self.sortName = sortName
    }
}

public struct WorkCreator: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "work_creator"

    public var workId: UUID
    public var creatorId: UUID
    public var role: CreatorRole
    public var position: Int

    public init(workId: UUID, creatorId: UUID, role: CreatorRole = .author, position: Int = 0) {
        self.workId = workId
        self.creatorId = creatorId
        self.role = role
        self.position = position
    }
}

public struct EditionCreator: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "edition_creator"

    public var editionId: UUID
    public var creatorId: UUID
    public var role: CreatorRole
    public var position: Int

    public init(editionId: UUID, creatorId: UUID, role: CreatorRole, position: Int = 0) {
        self.editionId = editionId
        self.creatorId = creatorId
        self.role = role
        self.position = position
    }
}

// MARK: - Collections
//
// À l'import, l'arborescence de dossiers de l'utilisateur devient des collections
// éditables : le classement déjà fait est respecté, jamais écrasé.

public struct BookCollection: Identifiable, Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "collection"

    public var id: UUID
    public var name: String
    public var parentId: UUID?
    /// Chemin du dossier source dont cette collection est issue, le cas échéant.
    public var sourceFolderPath: String?

    public init(id: UUID = UUID(), name: String, parentId: UUID? = nil, sourceFolderPath: String? = nil) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.sourceFolderPath = sourceFolderPath
    }
}

public struct CollectionItem: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "collection_item"

    public var collectionId: UUID
    public var workId: UUID

    public init(collectionId: UUID, workId: UUID) {
        self.collectionId = collectionId
        self.workId = workId
    }
}

/// Un dossier observé par la bibliothèque. Une bibliothèque peut en agréger plusieurs.
public struct SourceFolder: Identifiable, Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "source_folder"

    public var id: UUID
    public var path: String
    public var dateAdded: Date

    public init(id: UUID = UUID(), path: String, dateAdded: Date = Date()) {
        self.id = id
        self.path = path
        self.dateAdded = dateAdded
    }
}
