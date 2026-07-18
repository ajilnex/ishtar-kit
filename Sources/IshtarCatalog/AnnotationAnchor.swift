import Foundation
import GRDB

/// Retrouve un surlignement dans les pages extraites d'un document — par le
/// TEXTE (casse et diacritiques repliées), la page mémorisée n'étant qu'un
/// indice. C'est ce qui rend l'ancrage robuste au remplacement du fichier
/// (décision d'Aubin, 18/07).
public enum AnnotationAnchor {
    public enum Resolution: Equatable, Sendable {
        /// Trouvé à la page mémorisée (ou trouvée) — la vie normale.
        case found(pageNumber: Int)
        /// Trouvé, mais AILLEURS que la page mémorisée (fichier remplacé ?).
        case moved(from: Int?, to: Int)
        /// Introuvable dans le texte actuel (passage disparu, OCR différent).
        case lost
    }

    /// Repli neutre : sans casse ni diacritiques (même mécanique que la
    /// vérification des citations du démon), et blancs compactés — un passage
    /// sélectionné sur plusieurs lignes porte des sauts de ligne que le texte
    /// extrait espace autrement : l'ancrage ne doit pas s'y perdre.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Cherche la citation dans `document_page` : d'abord la page mémorisée,
    /// puis tout le document. Si la citation apparaît sur plusieurs pages,
    /// `prefix`+quote+`suffix` départage ; sinon la première occurrence gagne.
    public static func resolve(_ annotation: Annotation,
                               in db: CatalogDatabase) async throws -> Resolution {
        let pages: [(number: Int, content: String)] = try await db.pool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT pageNumber, content FROM document_page
                WHERE documentId = ? ORDER BY pageNumber
                """, arguments: [annotation.documentId])
            return rows.map { ($0["pageNumber"], $0["content"]) }
        }
        guard !pages.isEmpty else { return .lost }

        let quote = fold(annotation.quote)
        guard !quote.isEmpty else { return .lost }

        let hits = pages.filter { fold($0.content).contains(quote) }
        guard !hits.isEmpty else { return .lost }

        // La page mémorisée d'abord : si la citation s'y trouve, rien n'a bougé.
        if let remembered = annotation.pageNumber,
           hits.contains(where: { $0.number == remembered }) {
            return .found(pageNumber: remembered)
        }

        // Plusieurs candidates : le contexte (prefix + quote + suffix) départage.
        let target: Int
        if hits.count > 1 {
            let contextual = fold((annotation.prefix ?? "") + annotation.quote
                                  + (annotation.suffix ?? ""))
            target = hits.first(where: { fold($0.content).contains(contextual) })?.number
                ?? hits[0].number
        } else {
            target = hits[0].number
        }

        if annotation.pageNumber == nil {
            return .found(pageNumber: target)
        }
        return .moved(from: annotation.pageNumber, to: target)
    }
}
