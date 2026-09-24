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

    /// La forme de classement d'une personne (« Adorno, Theodor W. »).
    public func setSortName(_ sortName: String?, forCreator id: UUID) async throws {
        try await db.pool.write { conn in
            try conn.execute(sql: "UPDATE creator SET sortName = ? WHERE id = ?", arguments: [sortName, id])
        }
    }

    /// Date de l'œuvre et note de provenance d'une correction (« Corrigé
    /// sur la page de titre… »), sans toucher à la confiance.
    public func annotateWork(_ workId: UUID, date: String?, note: String?) async throws {
        try await db.pool.write { conn in
            if let date { try conn.execute(sql: "UPDATE work SET date = ? WHERE id = ?", arguments: [date, workId]) }
            if let note {
                try conn.execute(sql: """
                    UPDATE work SET notes = CASE WHEN notes IS NULL OR notes = '' THEN ? ELSE notes || char(10) || ? END WHERE id = ?
                    """, arguments: [note, note, workId])
            }
            try EditionKey.refreshProvisional(forWork: workId, conn)
        }
    }

    /// Le document dont le fichier porte ce nom (dans n'importe quel dossier),
    /// s'il est unique : (document, édition, œuvre).
    public func document(named fileName: String) async throws -> (documentId: UUID, editionId: UUID?, workId: UUID)? {
        try await db.pool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT d.id AS d, d.editionId AS e, ed.workId AS w FROM document d LEFT JOIN edition ed ON ed.id = d.editionId
                WHERE d.filePath LIKE ? ESCAPE '\\' AND d.isMissing = 0
                """, arguments: ["%/" + fileName.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")])
            guard rows.count == 1, let w: UUID = rows[0]["w"] else { return nil }
            return (rows[0]["d"], rows[0]["e"], w)
        }
    }

    /// Sépare une fiche de personne qui en nommait plusieurs (« Newen-Montemayor »)
    /// en autant de personnes, à la même place dans chaque œuvre. Rend le
    /// nombre d'œuvres touchées.
    @discardableResult
    public func splitCreator(named name: String, into names: [String]) async throws -> Int {
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard clean.count >= 2 else { return 0 }
        return try await db.pool.write { conn in
            guard let old = try Creator.filter(Column("name") == name).fetchOne(conn) else { return 0 }
            let links = try WorkCreator.filter(Column("creatorId") == old.id).fetchAll(conn)
            for link in links {
                // Les suivants se glissent après la place de l'ancien nom.
                try conn.execute(sql: "UPDATE work_creator SET position = position + ? WHERE workId = ? AND role = ? AND position > ?",
                                 arguments: [clean.count - 1, link.workId, link.role, link.position])
                try link.delete(conn)
                for (offset, n) in clean.enumerated() {
                    let person = try Creator.filter(Column("name") == n).fetchOne(conn)
                        ?? { let c = Creator(name: n); try c.insert(conn); return c }()
                    try WorkCreator(workId: link.workId, creatorId: person.id, role: link.role, position: link.position + offset)
                        .insert(conn, onConflict: .ignore)
                }
                try EditionKey.refreshProvisional(forWork: link.workId, conn)
            }
            try conn.execute(sql: "DELETE FROM authority_link WHERE entityType = 'creator' AND entityId = ?", arguments: [old.id])
            try conn.execute(sql: "DELETE FROM creator WHERE id = ?", arguments: [old.id])
            return links.count
        }
    }

    /// L'identifiant d'une personne par son nom exact.
    public func creatorId(named name: String) async throws -> UUID? {
        try await db.pool.read { try UUID.fetchOne($0, sql: "SELECT id FROM creator WHERE name = ?", arguments: [name]) }
    }
}
