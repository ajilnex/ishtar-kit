import Foundation
import IshtarCatalog

// Squelette du démon (M0). Aucune implémentation réseau ici : ce fichier fixe les
// contrats que l'app et les fournisseurs devront respecter, pour qu'il n'existe
// jamais deux pipelines concurrents (invariant n° 3).

// MARK: - Contexte d'invocation

/// Le démon n'est jamais appelé « à vide » : chaque invocation est ancrée
/// à un endroit de la bibliothèque (décision produit : interface « infusée »).
public enum InvocationContext: Sendable, Hashable {
    case library
    case work(UUID)
    case document(UUID)
    /// Une sélection dans un document : l'ancre est la citation exacte du passage.
    case selection(documentId: UUID, page: Int?, quote: String)
    case collection(UUID)
    case curationItem(workId: UUID)
}

// MARK: - Flux d'événements

/// L'unique flux d'événements du démon vers l'interface.
public enum DaemonEvent: Sendable {
    case thought(String)
    case token(String)
    case toolCall(name: String, summary: String)
    case uiCommand(UICommand)
    /// Les citations vérifiées de la réponse : l'app les rend en puces
    /// cliquables (« Titre », p. N → ouvrir, surbrillance transitoire).
    case citations([CitationChip])
    case finished
    case failed(message: String)
}

/// Une citation vérifiée, prête pour l'interface.
public struct CitationChip: Sendable, Identifiable, Equatable {
    public var id: String { "\(documentId)-\(page)" }
    public let documentId: UUID
    public let page: Int
    public let title: String
    /// Les mots exacts, pour la surbrillance transitoire à l'ouverture.
    public let quote: String?
    /// Faux si la citation n'a pas pu être vérifiée (texte non extrait, ou
    /// échec resté après le budget de corrections) — l'app l'affiche marquée.
    public let verified: Bool

    public init(documentId: UUID, page: Int, title: String,
                quote: String?, verified: Bool) {
        self.documentId = documentId
        self.page = page
        self.title = title
        self.quote = quote
        self.verified = verified
    }
}

/// Commandes que le démon peut adresser à l'interface — dont son geste signature :
/// ouvrir un document au bon endroit, passage surligné.
public enum UICommand: Sendable {
    case openDocument(id: UUID, page: Int?, highlight: String?)
}

// MARK: - Fournisseurs (BYOK + local)

public struct ChatMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Abstraction de fournisseur : Anthropic, OpenAI, Gemini, Mistral (BYOK, URLSession)
/// et modèles locaux MLX. Implémentations aux jalons M3.
public protocol ChatProvider: Sendable {
    var displayName: String { get }
    /// Vrai si l'inférence a lieu sur la machine (aucun contenu ne sort — pilier confidentialité).
    var isLocal: Bool { get }
    func stream(messages: [ChatMessage], context: InvocationContext) -> AsyncThrowingStream<DaemonEvent, Error>
}

/// Abstraction d'embeddings. Par défaut : local (le contenu de la bibliothèque
/// ne quitte jamais la machine sans opt-in explicite).
public protocol EmbeddingProvider: Sendable {
    var isLocal: Bool { get }
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

// MARK: - Outils

/// Registre des outils offerts au démon. Les noms sont figés dès M0 pour que les
/// prompts, la documentation et les tests parlent la même langue.
/// `readMemory`/`writeMemory` sont réservés (mémoire du démon, activation M4) :
/// la mémoire sera des fichiers Markdown lisibles, jamais une boîte noire.
public enum DaemonTool: String, CaseIterable, Sendable {
    case searchCatalog = "search_catalog"
    case searchFulltext = "search_fulltext"
    case semanticSearch = "semantic_search"
    case readPage = "read_page"
    case openDocument = "open_document"
    case createArtifact = "create_artifact"
    case createLink = "create_link"
    case listAnnotations = "list_annotations"
    case proposeMetadata = "propose_metadata"
    case readMemory = "read_memory"
    case writeMemory = "write_memory"

    /// Outils exposés en v1 (M3). Les autres attendent leur jalon.
    public static let v1: [DaemonTool] = [
        .searchCatalog, .searchFulltext, .semanticSearch,
        .readPage, .openDocument, .createArtifact, .proposeMetadata,
    ]
}
