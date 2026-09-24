import Foundation
import GRDB

extension CatalogStore {
    /// Écrit une restauration typographique (voir `TypographyRestorer`).
    ///
    /// Ne touche jamais une œuvre en confiance haute : la main de l'utilisateur
    /// l'emporte toujours. Ne change pas la confiance : une graphie mieux
    /// écrite n'est pas une vérification. L'auteur n'est pas renommé partout :
    /// seule cette œuvre est rattachée à la graphie complète, pour qu'un
    /// homonyme ailleurs ne soit pas emporté.
    ///
    /// - Returns: vrai si quelque chose a changé.
    @discardableResult
    public func applyTypography(workId: UUID, title: String?,
                                author: (from: String, to: String)?) async throws -> Bool {
        try await db.pool.write { conn in
            guard var work = try Work.fetchOne(conn, key: workId), work.confidence != .high else { return false }
            var changed = false

            if let title, title != work.title {
                work.title = title
                try work.update(conn)
                changed = true
            }

            if let author, author.from != author.to,
               let link = try WorkCreator.fetchOne(conn, sql: """
                   SELECT wc.* FROM work_creator wc JOIN creator c ON c.id = wc.creatorId
                   WHERE wc.workId = ? AND wc.role = 'author' AND c.name = ?
                   """, arguments: [workId, author.from]) {
                let target = try Creator.filter(Column("name") == author.to).fetchOne(conn)
                    ?? { let c = Creator(name: author.to); try c.insert(conn); return c }()
                try link.delete(conn)
                try WorkCreator(workId: workId, creatorId: target.id, role: .author, position: link.position)
                    .insert(conn, onConflict: .ignore)
                try conn.execute(sql: """
                    DELETE FROM creator WHERE id NOT IN (SELECT creatorId FROM work_creator)
                        AND id NOT IN (SELECT creatorId FROM edition_creator)
                    """)
                changed = true
            }

            if changed { try EditionKey.refreshProvisional(forWork: workId, conn) }
            return changed
        }
    }
}
