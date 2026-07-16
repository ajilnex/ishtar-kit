import Foundation
import GRDB
import IshtarCatalog
import IshtarSearch

/// La boîte à outils du démon : ce qu'il sait FAIRE sur la bibliothèque.
/// Quatre outils v1, minimaux et sûrs — chercher (hybride), lire une page,
/// ouvrir un document au bon endroit (surbrillance transitoire), situer la
/// bibliothèque. Tout est local ; `open_document` ne fait qu'émettre une
/// commande d'interface.
public struct DaemonToolbox: Sendable {
    let db: CatalogDatabase
    let semantic: SemanticSearch?

    public init(db: CatalogDatabase, semantic: SemanticSearch?) {
        self.db = db
        self.semantic = semantic
    }

    public var specs: [LLMToolSpec] {
        [
            LLMToolSpec(
                name: "search_library",
                description: """
                Recherche dans la bibliothèque (plein texte + sémantique). \
                Retourne des passages avec document_id, titre, page et extrait. \
                Utilise-la pour retrouver un passage, même décrit vaguement.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{"query":{"type":"string","description":"Les termes ou la description du passage cherché"}},"required":["query"]}
                """#),
            LLMToolSpec(
                name: "read_page",
                description: "Lit le texte d'une page précise d'un document (document_id + page).",
                parametersJSON: #"""
                {"type":"object","properties":{"document_id":{"type":"string"},"page":{"type":"integer"}},"required":["document_id","page"]}
                """#),
            LLMToolSpec(
                name: "open_document",
                description: """
                Ouvre un document dans le lecteur, à une page donnée, avec une \
                mise en surbrillance transitoire des termes fournis. Utilise-la \
                pour MONTRER un passage au chercheur après l'avoir trouvé.
                """,
                parametersJSON: #"""
                {"type":"object","properties":{"document_id":{"type":"string"},"page":{"type":"integer"},"highlight":{"type":"string","description":"Quelques mots exacts du passage à mettre en surbrillance"}},"required":["document_id","page"]}
                """#),
            LLMToolSpec(
                name: "library_stats",
                description: "Vue d'ensemble : nombre de documents, statuts, exemples de titres.",
                parametersJSON: #"{"type":"object","properties":{}}"#),
        ]
    }

    /// Exécute un appel d'outil. Retourne le résultat textuel pour le modèle et,
    /// le cas échéant, une commande d'interface (jamais exécutée ici : c'est
    /// l'app qui décide de l'appliquer — séparation stricte).
    public func execute(name: String, argumentsJSON: String) async -> (result: String, ui: UICommand?) {
        let args = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]

        switch name {
        case "search_library":
            guard let query = args["query"] as? String, !query.isEmpty else {
                return ("Erreur : paramètre 'query' manquant.", nil)
            }
            return (await searchLibrary(query), nil)

        case "read_page":
            guard let idString = args["document_id"] as? String,
                  let documentId = UUID(uuidString: idString),
                  let page = args["page"] as? Int else {
                return ("Erreur : 'document_id' (UUID) et 'page' (entier) requis.", nil)
            }
            return (await readPage(documentId: documentId, page: page), nil)

        case "open_document":
            guard let idString = args["document_id"] as? String,
                  let documentId = UUID(uuidString: idString),
                  let page = args["page"] as? Int else {
                return ("Erreur : 'document_id' (UUID) et 'page' (entier) requis.", nil)
            }
            let highlight = args["highlight"] as? String
            return ("Document ouvert à la page \(page) pour le chercheur.",
                    .openDocument(id: documentId, page: page, highlight: highlight))

        case "library_stats":
            return (await stats(), nil)

        default:
            return ("Outil inconnu : \(name)", nil)
        }
    }

    // MARK: Implémentations

    private func searchLibrary(_ query: String) async -> String {
        // Voie hybride si l'index sémantique existe, sinon plein texte seul.
        if let semantic {
            if let hits = try? await semantic.search(query, limit: 8), !hits.isEmpty {
                return hits.map { hit in
                    let authors = hit.authors.isEmpty ? "" : " (\(hit.authors.joined(separator: ", ")))"
                    return """
                    - document_id: \(hit.documentId) | « \(hit.title) »\(authors), p. \(hit.pageNumber)
                      extrait : \(hit.excerpt.replacingOccurrences(of: "\n", with: " "))
                    """
                }.joined(separator: "\n")
            }
        }
        if let hits = try? await FulltextSearch(db: db).search(query, limit: 8), !hits.isEmpty {
            return hits.map { hit in
                "- document_id: \(hit.documentId) | « \(hit.title) », p. \(hit.pageNumber)\n  extrait : \(hit.snippet)"
            }.joined(separator: "\n")
        }
        return "Aucun passage trouvé pour « \(query) »."
    }

    private func readPage(documentId: UUID, page: Int) async -> String {
        let content: String? = try? await db.pool.read { conn in
            try String.fetchOne(conn, sql: """
                SELECT content FROM document_page
                WHERE documentId = ? AND pageNumber = ?
                """, arguments: [documentId, page])
        }
        guard let content, !content.isEmpty else {
            return "Page \(page) introuvable ou non extraite pour ce document."
        }
        return String(content.prefix(4000))
    }

    private func stats() async -> String {
        let overview = LibraryOverview(db: db)
        guard let stats = try? await overview.stats(),
              let rows = try? await overview.rows() else {
            return "Bibliothèque indisponible."
        }
        let sample = rows.prefix(12)
            .map { row -> String in
                let authors = row.authors.joined(separator: ", ")
                return authors.isEmpty ? "« \(row.work.title) »"
                                       : "« \(row.work.title) » — \(authors)"
            }
            .joined(separator: " ; ")
        return """
        \(stats.total) documents (reconnus : \(stats.recognized), à identifier : \
        \(stats.needsReview), doublons possibles : \(stats.duplicates)).
        Exemples : \(sample)
        """
    }
}
