import Foundation
import GRDB

/// Un fil de conversation avec le démon.
public struct Conversation: Identifiable, Codable, Hashable, Sendable,
                            FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversation"

    public var id: UUID
    /// Titre lisible dans l'historique. Nul tant que le fil n'a rien dit :
    /// `ConversationTitle` le dérive de la première question.
    public var title: String?
    public var dateCreated: Date
    /// Touchée à chaque message — c'est elle qui ordonne l'historique.
    public var dateModified: Date

    public init(id: UUID = UUID(), title: String? = nil,
                dateCreated: Date = Date(), dateModified: Date = Date()) {
        self.id = id
        self.title = title
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }
}

/// Un message tel qu'il a été MONTRÉ à l'utilisateur.
///
/// Ce qui n'est **pas** enregistré : les appels d'outils bruts et les jetons
/// propres à un fournisseur — la signature de pensée que Gemini 3 attache à ses
/// appels, par exemple. Ils sont opaques, périssables, et liés à un fournisseur
/// précis. Reprendre un fil rejoue donc l'échange visible en messages simples,
/// ce qui permet d'ouvrir une conversation avec Gemini et de la poursuivre avec
/// un modèle local sans que l'un hérite des jetons de l'autre.
public struct ConversationMessage: Identifiable, Codable, Hashable, Sendable,
                                   FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversation_message"

    public enum Role: String, Codable, Sendable, DatabaseValueConvertible {
        case user, assistant
        /// Trace d'un outil : la fine ligne grise affichée sous la question.
        case tool
    }

    public var id: UUID
    public var conversationId: UUID
    /// Rang dans le fil, à partir de zéro. Le magasin le calcule.
    public var position: Int
    public var role: Role
    public var content: String
    /// Puces de citation vérifiées, déjà sérialisées ; nul si la réponse n'en
    /// portait aucune. Le moteur ne les interprète pas : l'interface les rend.
    public var citationsJSON: String?
    public var dateCreated: Date

    public init(id: UUID = UUID(), conversationId: UUID, position: Int,
                role: Role, content: String, citationsJSON: String? = nil,
                dateCreated: Date = Date()) {
        self.id = id
        self.conversationId = conversationId
        self.position = position
        self.role = role
        self.content = content
        self.citationsJSON = citationsJSON
        self.dateCreated = dateCreated
    }
}

/// L'historique des conversations : ouvrir un fil, y empiler des messages, les
/// relire, renommer, supprimer. Rien d'autre — la boucle du démon vit ailleurs.
public struct ConversationStore: Sendable {
    let db: CatalogDatabase

    public init(db: CatalogDatabase) {
        self.db = db
    }

    @discardableResult
    public func start(title: String? = nil) async throws -> Conversation {
        let conversation = Conversation(title: title)
        try await db.pool.write { conn in try conversation.insert(conn) }
        return conversation
    }

    /// Empile un message à la fin du fil et touche sa date. Le rang est calculé
    /// ici : l'appelant n'a pas à compter. Le premier message d'utilisateur
    /// nomme le fil s'il ne l'est pas encore.
    @discardableResult
    public func append(to conversationId: UUID, role: ConversationMessage.Role,
                       content: String,
                       citationsJSON: String? = nil) async throws -> ConversationMessage {
        try await db.pool.write { conn in
            let next = try Int.fetchOne(conn, sql: """
                SELECT COALESCE(MAX(position), -1) + 1 FROM conversation_message
                WHERE conversationId = ?
                """, arguments: [conversationId]) ?? 0

            let message = ConversationMessage(
                conversationId: conversationId, position: next,
                role: role, content: content, citationsJSON: citationsJSON)
            try message.insert(conn)

            if var conversation = try Conversation.fetchOne(conn, key: conversationId) {
                conversation.dateModified = message.dateCreated
                if conversation.title == nil, role == .user {
                    conversation.title = ConversationTitle.derived(from: content)
                }
                try conversation.update(conn)
            }
            return message
        }
    }

    /// Les messages d'un fil, dans l'ordre où ils ont été dits.
    public func messages(of conversationId: UUID) async throws -> [ConversationMessage] {
        try await db.pool.read { conn in
            try ConversationMessage
                .filter(Column("conversationId") == conversationId)
                .order(Column("position"))
                .fetchAll(conn)
        }
    }

    /// Les fils les plus récemment nourris d'abord — l'ordre de l'historique.
    public func recent(limit: Int = 30) async throws -> [Conversation] {
        try await db.pool.read { conn in
            try Conversation
                .order(Column("dateModified").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    public func rename(id: UUID, to title: String?) async throws {
        try await db.pool.write { conn in
            guard var conversation = try Conversation.fetchOne(conn, key: id) else { return }
            conversation.title = title
            conversation.dateModified = Date()
            try conversation.update(conn)
        }
    }

    public func remove(id: UUID) async throws {
        _ = try await db.pool.write { conn in
            try Conversation.deleteOne(conn, key: id)
        }
    }

    /// Efface les fils ouverts puis abandonnés sans un mot. Sans ce ménage,
    /// chaque clic sur « nouvelle conversation » laisserait une coquille dans
    /// l'historique.
    public func purgeEmpty() async throws {
        _ = try await db.pool.write { conn in
            try conn.execute(sql: """
                DELETE FROM conversation WHERE id NOT IN
                    (SELECT DISTINCT conversationId FROM conversation_message)
                """)
        }
    }
}

/// Le titre d'un fil, dérivé de sa première question. Pur, donc testé sans base.
public enum ConversationTitle {
    /// Tronque sur une frontière de mot : couper au milieu d'un mot se voit, et
    /// se lit mal dans une liste.
    public static func derived(from question: String, limit: Int = 60) -> String? {
        let normalized = question
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > limit else { return normalized }

        let cut = normalized.index(normalized.startIndex, offsetBy: limit)
        let head = normalized[..<cut]
        guard let lastSpace = head.lastIndex(of: " ") else {
            return String(head) + "…"
        }
        return String(normalized[..<lastSpace]) + "…"
    }
}
