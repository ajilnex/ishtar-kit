import Foundation
import NaturalLanguage

/// Les embeddings LOCAUX d'Apple (`NLContextualEmbedding`, script latin —
/// multilingue FR/EN/DE…). Rien ne quitte la machine : le contenu de la
/// bibliothèque n'est jamais envoyé nulle part (pilier confidentialité).
/// Le modèle lui-même est un actif système téléchargé une fois par macOS.
public final class LocalEmbeddings: @unchecked Sendable {
    private let embedding: NLContextualEmbedding
    /// Sérialise les accès : NLContextualEmbedding n'est pas documenté thread-safe.
    private let lock = NSLock()

    public let modelID: String
    public var dimension: Int { embedding.dimension }

    public enum EmbeddingError: LocalizedError {
        case modelUnavailable
        case assetsMissing

        public var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                "Le modèle d'embeddings local n'est pas disponible sur ce système."
            case .assetsMissing:
                "Les ressources du modèle d'embeddings ne sont pas encore téléchargées."
            }
        }
    }

    public init() throws {
        guard let emb = NLContextualEmbedding(script: .latin) else {
            throw EmbeddingError.modelUnavailable
        }
        embedding = emb
        modelID = "nl-contextual-latin-\(emb.revision)"
    }

    public var hasAssets: Bool { embedding.hasAvailableAssets }

    /// Demande à macOS de télécharger les ressources du modèle si nécessaire
    /// (téléchargement système, une fois). Retourne quand elles sont prêtes.
    public func ensureAssets() async throws {
        if embedding.hasAvailableAssets {
            try loadIfNeeded()
            return
        }
        let result = try await embedding.requestAssets()
        guard result == .available else { throw EmbeddingError.assetsMissing }
        try loadIfNeeded()
    }

    private func loadIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if !embedding.hasAvailableAssets { throw EmbeddingError.assetsMissing }
        // `load()` est idempotent ; le recharger ne coûte rien s'il l'est déjà.
        try embedding.load()
    }

    /// Vecteur d'un texte : moyenne des vecteurs de jetons (mean pooling),
    /// normalisée L2 — la distance L2 de vec0 ordonne alors comme le cosinus.
    /// Le texte est tronqué (~1 500 caractères) : suffisant pour situer une page.
    public func embed(_ text: String) throws -> [Float] {
        let clipped = String(text.prefix(1500))
        lock.lock()
        defer { lock.unlock() }
        let result = try embedding.embeddingResult(for: clipped, language: nil)

        var sum = [Double](repeating: 0, count: embedding.dimension)
        var count = 0
        result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
            for (i, v) in vector.enumerated() { sum[i] += v }
            count += 1
            return true
        }
        guard count > 0 else { return [Float](repeating: 0, count: embedding.dimension) }

        var mean = sum.map { Float($0 / Double(count)) }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { mean = mean.map { $0 / norm } }
        return mean
    }
}
