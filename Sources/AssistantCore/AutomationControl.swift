import Foundation
import SQLite3

public enum AutomationControlState: String, Codable, CaseIterable, Sendable {
    case automatic
    case humanTakeover
    case automationPaused
    case awaitingManualResume

    public var blocksPhoneControl: Bool {
        self != .automatic
    }
}

public struct AutomationControlRecord: Codable, Equatable, Sendable {
    public let state: AutomationControlState
    public let generation: Int
    public let updatedAt: Date
    public let actor: String
    public let reason: String

    public init(
        state: AutomationControlState,
        generation: Int,
        updatedAt: Date,
        actor: String,
        reason: String
    ) {
        self.state = state
        self.generation = generation
        self.updatedAt = updatedAt
        self.actor = actor
        self.reason = reason
    }
}

public struct AutomationControlAuditEvent: Equatable, Sendable {
    public let generation: Int
    public let state: AutomationControlState
    public let updatedAt: Date
    public let actor: String
    public let reason: String

    public init(
        generation: Int,
        state: AutomationControlState,
        updatedAt: Date,
        actor: String,
        reason: String
    ) {
        self.generation = generation
        self.state = state
        self.updatedAt = updatedAt
        self.actor = actor
        self.reason = reason
    }
}

public enum AutomationControlError: Error, Equatable {
    case invalidTransition(
        from: AutomationControlState,
        to: AutomationControlState
    )
    case corruptState
}

/// SQLite-backed emergency-control lock.
///
/// The row is deliberately fail-closed: a new database starts in
/// `humanTakeover`, not `automatic`. Code that needs automatic control must
/// explicitly transition through `awaitingManualResume` first.
public final class SQLiteAutomationControlStore: @unchecked Sendable {
    private let database: SQLiteDatabase
    private let lock = NSLock()
    private let clock: @Sendable () -> Date

    public init(
        databaseURL: URL,
        initialReason: String = "Fail closed on first launch",
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.database = try SQLiteDatabase(url: databaseURL)
        self.clock = clock
        try Self.createSchema(database)
        lock.lock()
        defer { lock.unlock() }
        let insert = try database.prepare(
            """
            INSERT OR IGNORE INTO automation_control (
                id, state, generation, updated_at, actor, reason
            ) VALUES (1, ?, 1, ?, 'system', ?)
            """
        )
        insert.bind(1, AutomationControlState.humanTakeover.rawValue)
        insert.bind(2, clock().timeIntervalSince1970)
        insert.bind(3, initialReason)
        _ = try insert.step()
    }

    public func current() throws -> AutomationControlRecord {
        lock.lock()
        defer { lock.unlock() }
        return try currentLocked()
    }

    public func update(
        to target: AutomationControlState,
        actor: String,
        reason: String
    ) throws -> AutomationControlRecord {
        lock.lock()
        defer { lock.unlock() }

        let before = try currentLocked()
        guard Self.canTransition(from: before.state, to: target) else {
            throw AutomationControlError.invalidTransition(
                from: before.state,
                to: target
            )
        }
        if before.state == target {
            return before
        }

        let now = clock()
        let generation = before.generation + 1
        try database.execute("BEGIN IMMEDIATE")
        do {
            let update = try database.prepare(
                """
                UPDATE automation_control
                SET state = ?, generation = ?, updated_at = ?, actor = ?,
                    reason = ?
                WHERE id = 1 AND generation = ?
                """
            )
            update.bind(1, target.rawValue)
            update.bind(2, generation)
            update.bind(3, now.timeIntervalSince1970)
            update.bind(4, actor)
            update.bind(5, reason)
            update.bind(6, before.generation)
            _ = try update.step()
            guard database.changes == 1 else {
                throw AutomationControlError.corruptState
            }

            let audit = try database.prepare(
                """
                INSERT INTO automation_control_audit (
                    generation, state, updated_at, actor, reason
                ) VALUES (?, ?, ?, ?, ?)
                """
            )
            audit.bind(1, generation)
            audit.bind(2, target.rawValue)
            audit.bind(3, now.timeIntervalSince1970)
            audit.bind(4, actor)
            audit.bind(5, reason)
            _ = try audit.step()
            try database.execute("COMMIT")
            return AutomationControlRecord(
                state: target,
                generation: generation,
                updatedAt: now,
                actor: actor,
                reason: reason
            )
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    public func auditTrail() throws -> [AutomationControlAuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try database.prepare(
            """
            SELECT generation, state, updated_at, actor, reason
            FROM automation_control_audit
            ORDER BY id ASC
            """
        )
        var output: [AutomationControlAuditEvent] = []
        while try statement.step() == SQLITE_ROW {
            guard let raw = statement.text(1),
                  let state = AutomationControlState(rawValue: raw)
            else {
                throw AutomationControlError.corruptState
            }
            output.append(
                AutomationControlAuditEvent(
                    generation: statement.int(0),
                    state: state,
                    updatedAt: Date(
                        timeIntervalSince1970: statement.double(2)
                    ),
                    actor: statement.text(3) ?? "",
                    reason: statement.text(4) ?? ""
                )
            )
        }
        return output
    }

    public static func canTransition(
        from source: AutomationControlState,
        to target: AutomationControlState
    ) -> Bool {
        if source == target {
            return true
        }
        switch target {
        case .humanTakeover, .automationPaused:
            return true
        case .awaitingManualResume:
            return source == .humanTakeover || source == .automationPaused
        case .automatic:
            return source == .awaitingManualResume
        }
    }

    private func currentLocked() throws -> AutomationControlRecord {
        let statement = try database.prepare(
            """
            SELECT state, generation, updated_at, actor, reason
            FROM automation_control
            WHERE id = 1
            LIMIT 1
            """
        )
        guard try statement.step() == SQLITE_ROW else {
            throw AutomationControlError.corruptState
        }
        guard let raw = statement.text(0),
              let state = AutomationControlState(rawValue: raw)
        else {
            throw AutomationControlError.corruptState
        }
        return AutomationControlRecord(
            state: state,
            generation: statement.int(1),
            updatedAt: Date(
                timeIntervalSince1970: statement.double(2)
            ),
            actor: statement.text(3) ?? "",
            reason: statement.text(4) ?? ""
        )
    }

    private static func createSchema(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS automation_control (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                state TEXT NOT NULL,
                generation INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                actor TEXT NOT NULL,
                reason TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS automation_control_audit (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                generation INTEGER NOT NULL,
                state TEXT NOT NULL,
                updated_at REAL NOT NULL,
                actor TEXT NOT NULL,
                reason TEXT NOT NULL
            );
            """
        )
    }
}
