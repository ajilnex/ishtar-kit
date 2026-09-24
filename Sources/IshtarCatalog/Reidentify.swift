import Foundation
import GRDB

extension CatalogStore {
    /// Renomme une personne. Si une autre fiche porte déjà ce nom, les deux
    /// fusionnent : œuvres, éditions et liens d'autorité passent à celle qui
    /// existait, la fiche renommée disparaît. Rend l'identifiant retenu.
    @discardableResult
    public func renameCreator(_ id: UUID, to name: String) async throws -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw DatabaseError(message: "Le nom ne peut pas être vide.") }
        return try await db.pool.write { conn in
            try Self.renameCreator(id, to: clean, conn)
        }
    }

    static func renameCreator(_ id: UUID, to name: String, _ conn: Database) throws -> UUID {
        guard var creator = try Creator.fetchOne(conn, key: id) else { return id }
        if let other = try Creator.filter(Column("name") == name && Column("id") != id).fetchOne(conn) {
            try merge(creator: id, into: other.id, conn)
            return other.id
        }
        creator.name = name
        try creator.update(conn)
        try refreshKeys(ofCreator: id, conn)
        return id
    }

    /// Fusion de deux fiches de personne (la première disparaît).
    static func merge(creator from: UUID, into to: UUID, _ conn: Database) throws {
        for table in ["work_creator", "edition_creator"] {
            try conn.execute(sql: "UPDATE OR IGNORE \(table) SET creatorId = ? WHERE creatorId = ?", arguments: [to, from])
            try conn.execute(sql: "DELETE FROM \(table) WHERE creatorId = ?", arguments: [from])
        }
        try conn.execute(sql: """
            UPDATE OR IGNORE authority_link SET entityId = ? WHERE entityType = 'creator' AND entityId = ?
            """, arguments: [to, from])
        try conn.execute(sql: "DELETE FROM authority_link WHERE entityType = 'creator' AND entityId = ?", arguments: [from])
        try conn.execute(sql: "DELETE FROM creator WHERE id = ?", arguments: [from])
        try refreshKeys(ofCreator: to, conn)
    }

    /// Les clés provisoires suivent le nom de famille de leur auteur.
    static func refreshKeys(ofCreator id: UUID, _ conn: Database) throws {
        let works = try UUID.fetchAll(conn, sql: "SELECT DISTINCT workId FROM work_creator WHERE creatorId = ?", arguments: [id])
        for work in works { try EditionKey.refreshProvisional(forWork: work, conn) }
    }

    /// Réidentification d'une œuvre qui n'est pas passée par une main
    /// humaine : titre relu, année de l'œuvre (l'année d'édition reste), et un
    /// auteur pour une œuvre qui n'en avait pas. Rend vrai si quelque chose a
    /// changé.
    @discardableResult
    public func reidentify(workId: UUID, title: String?, workDate: String?, authorForAnonymous: String?) async throws -> Bool {
        try await db.pool.write { conn in
            guard var work = try Work.fetchOne(conn, key: workId), work.confidence != .high else { return false }
            var changed = false
            if let title, !title.isEmpty, title != work.title { work.title = title; changed = true }
            if let workDate, workDate != work.date { work.date = workDate; changed = true }
            if changed, work.confidence == .low { work.confidence = .probable }
            if changed { try work.update(conn) }

            if let author = authorForAnonymous?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty,
               try WorkCreator.filter(Column("workId") == workId && Column("role") == CreatorRole.author.rawValue).fetchCount(conn) == 0 {
                let creator = try Creator.filter(Column("name") == author).fetchOne(conn)
                    ?? { let c = Creator(name: author); try c.insert(conn); return c }()
                try WorkCreator(workId: workId, creatorId: creator.id, role: .author, position: 0).insert(conn, onConflict: .ignore)
                if work.confidence == .low { work.confidence = .probable; try work.update(conn) }
                changed = true
            }
            if changed { try EditionKey.refreshProvisional(forWork: workId, conn) }
            return changed
        }
    }

    /// Remplace l'attribution d'une œuvre qui n'est pas passée par une main
    /// humaine. Les personnes sans plus aucune œuvre disparaissent, avec leurs
    /// liens d'autorité. Rend faux si l'œuvre est protégée.
    @discardableResult
    public func setAuthors(workId: UUID, _ names: [String]) async throws -> Bool {
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return false }
        return try await db.pool.write { conn in
            guard var work = try Work.fetchOne(conn, key: workId), work.confidence != .high else { return false }
            try WorkCreator.filter(Column("workId") == workId && Column("role") == CreatorRole.author.rawValue).deleteAll(conn)
            for (position, name) in clean.enumerated() {
                let creator = try Creator.filter(Column("name") == name).fetchOne(conn)
                    ?? { let c = Creator(name: name); try c.insert(conn); return c }()
                try WorkCreator(workId: workId, creatorId: creator.id, role: .author, position: position)
                    .insert(conn, onConflict: .ignore)
            }
            if work.confidence == .low { work.confidence = .probable; try work.update(conn) }
            try conn.execute(sql: """
                DELETE FROM creator WHERE id NOT IN (SELECT creatorId FROM work_creator)
                    AND id NOT IN (SELECT creatorId FROM edition_creator)
                """)
            try conn.execute(sql: """
                DELETE FROM authority_link WHERE entityType = 'creator' AND entityId NOT IN (SELECT id FROM creator)
                """)
            try EditionKey.refreshProvisional(forWork: workId, conn)
            return true
        }
    }
}
