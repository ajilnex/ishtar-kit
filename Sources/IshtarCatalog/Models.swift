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

/// Le moteur qui sait AFFICHER un format. Ce n'est pas une préférence : c'est
/// un constat technique, et la seule chose que le lecteur ait besoin de savoir.
public enum ReadingEngine: String, Sendable {
    /// PDFKit (Apple) — pagination, sélection, annotations natives.
    case pdfKit
    /// foliate-js (MIT, copie figée) dans la WKWebView au réseau coupé :
    /// EPUB, MOBI, AZW3/KF8, AZW non protégé, FB2, FBZ, CBZ.
    case foliate
    /// Rendu texte maison (TXT, MD) ou texte extrait (DOCX, DOC, RTF, ODT, HTML).
    case text
    /// Aucun moteur : le format est fermé (DRM) ou son seul décodeur est sous
    /// une licence incompatible. Le lecteur le dit, il ne le cache pas.
    case none
}

/// Pourquoi Ishtar ne sait pas ouvrir un document. Le lecteur affiche cette
/// raison telle quelle : jamais « format non géré » tout court.
public enum UnreadableReason: String, Sendable {
    /// Verrou éditeur (Kindle KFX, MOBI/AZW chiffré, EPUB Adobe DRM).
    case drm
    /// Décodeur existant mais sous licence GPL/propriétaire — interdit dans
    /// l'app (60-CAP §2 : BSD/MIT/Apache seulement). DJVU, CBR.
    case licenceIncompatible
    /// Fichier illisible : tronqué, corrompu, vide.
    case damaged
}

public enum DocumentFormat: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    // Historiques (ne jamais renommer : ce sont des valeurs en base).
    case pdf, epub, mobi, azw3, djvu, txt, md, docx, rtf
    // Ajouts du chantier « lecteur polyvalent ».
    case azw, fb2, fbz, cbz, cbr, kfx, html, doc, odt

    /// Extensions rencontrées dans les bibliothèques réelles, ramenées au
    /// format canonique. `fb2.zip` est traité en amont (double extension).
    private static let aliases: [String: DocumentFormat] = [
        "htm": .html, "xhtml": .html,
        "markdown": .md, "mdown": .md, "mkd": .md,
        "prc": .mobi, "pdb": .mobi,
        "azw4": .pdf,          // AZW4 est un PDF encapsulé Kindle
        "text": .txt,
        "djv": .djvu,
        "fb2z": .fbz,
    ]

    /// Depuis une extension de fichier. Insensible à la casse, tolérante aux
    /// variantes (`htm`, `prc`, `markdown`…).
    public init?(fileExtension: String) {
        let ext = fileExtension.lowercased()
        if let direct = DocumentFormat(rawValue: ext) {
            self = direct
        } else if let alias = DocumentFormat.aliases[ext] {
            self = alias
        } else {
            return nil
        }
    }

    /// Depuis un nom de fichier complet — seul endroit où la double extension
    /// `.fb2.zip` peut être vue.
    public init?(fileName: String) {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".fb2.zip") {
            self = .fbz
            return
        }
        self.init(fileExtension: (fileName as NSString).pathExtension)
    }

    /// Le moteur d'affichage. `none` n'est jamais un aveu vague : il
    /// s'accompagne toujours d'une `unreadableReason`.
    public var readingEngine: ReadingEngine {
        switch self {
        case .pdf: .pdfKit
        case .epub, .mobi, .azw3, .azw, .fb2, .fbz, .cbz: .foliate
        case .txt, .md, .html, .docx, .doc, .rtf, .odt: .text
        case .djvu, .cbr, .kfx: .none
        }
    }

    /// La raison, quand il n'y a pas de moteur. `nil` si le format se lit.
    /// (Un MOBI chiffré est décidé à l'ouverture, pas ici : c'est une propriété
    /// du fichier, pas du format.)
    public var unreadableReason: UnreadableReason? {
        switch self {
        case .kfx: .drm
        case .djvu, .cbr: .licenceIncompatible
        default: nil
        }
    }

    /// Vrai si le texte du document est indexable (recherche plein texte,
    /// démon). Les images sans couche texte (CBZ) n'en sont pas.
    public var isTextExtractable: Bool {
        switch self {
        case .pdf, .epub, .txt, .md, .mobi, .azw3, .azw, .fb2, .fbz,
             .html, .docx, .doc, .odt, .rtf: true
        case .cbz, .djvu, .cbr, .kfx: false
        }
    }

    /// Les formats que le lecteur interne ouvre — utilisé par l'app pour
    /// décider d'ouvrir une fenêtre plutôt que de déléguer au système.
    public var isReadableInIshtar: Bool { readingEngine != .none }
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

// MARK: - Projets et encres

public struct Project: Identifiable, Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"

    public var id: UUID
    public var name: String
    public var notes: String?
    public var dateCreated: Date
    public var dateModified: Date

    public init(id: UUID = UUID(), name: String, notes: String? = nil, dateCreated: Date = Date(), dateModified: Date = Date()) {
        self.id = id
        self.name = name
        self.notes = notes
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }
}

public struct ProjectItem: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project_item"

    public var projectId: UUID
    public var documentId: UUID
    public var dateAdded: Date

    public init(projectId: UUID, documentId: UUID, dateAdded: Date = Date()) {
        self.projectId = projectId
        self.documentId = documentId
        self.dateAdded = dateAdded
    }
}

/// Une relation colorée entre deux passages que le chercheur a marqués (encres).
public struct Link: Identifiable, Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "link"

    public var id: UUID
    public var kind: String
    public var color: String?
    public var projectId: UUID?
    public var sourceAnnotationId: UUID
    public var targetAnnotationId: UUID
    public var note: String?
    public var dateCreated: Date
    public var dateModified: Date

    public init(
        id: UUID = UUID(),
        kind: String,
        color: String? = nil,
        projectId: UUID? = nil,
        sourceAnnotationId: UUID,
        targetAnnotationId: UUID,
        note: String? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.projectId = projectId
        self.sourceAnnotationId = sourceAnnotationId
        self.targetAnnotationId = targetAnnotationId
        self.note = note
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }
}
