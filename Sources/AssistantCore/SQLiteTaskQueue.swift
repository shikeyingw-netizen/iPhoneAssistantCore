import Foundation
import SQLite3

public enum TaskQueueError: Error, Equatable {
    case emptyIdempotencyKey
    case taskNotFound
    case corruptPayload
    case noActiveLease
}

public actor SQLiteTaskQueue {
    private let database: SQLiteDatabase
    private let cipher: SensitivePayloadCipher
    private let clock: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        databaseURL: URL,
        cipher: SensitivePayloadCipher,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.database = try SQLiteDatabase(url: databaseURL)
        self.cipher = cipher
        self.clock = clock
        try Self.createSchema(database)
    }

    public func close() {
        // The connection closes when this actor and its statements are released.
    }

    public func enqueue(_ input: QueueTaskInput) throws -> QueueEnqueueResult {
        let key = input.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw TaskQueueError.emptyIdempotencyKey
        }
        let encryptedPayload = try cipher.encrypt(encoder.encode(input.payload))
        let statement = try database.prepare(
            """
            INSERT OR IGNORE INTO tasks (
                id, event_id, idempotency_key, platform, store_name, state,
                priority, available_at, created_at, updated_at, attempt_count,
                encrypted_payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """
        )
        statement.bind(1, input.id.uuidString)
        statement.bind(2, input.eventID)
        statement.bind(3, key)
        statement.bind(4, input.platform.rawValue)
        statement.bind(5, input.storeName)
        statement.bind(6, TaskState.queued.rawValue)
        statement.bind(7, input.priority.rawValue)
        statement.bind(8, input.availableAt.timeIntervalSince1970)
        statement.bind(9, input.createdAt.timeIntervalSince1970)
        statement.bind(10, input.createdAt.timeIntervalSince1970)
        statement.bind(11, encryptedPayload)
        _ = try statement.step()

        guard database.changes == 1 else {
            guard let existing = try task(byIdempotencyKey: key) else {
                throw TaskQueueError.taskNotFound
            }
            return .duplicate(existing)
        }
        guard let inserted = try task(byIdempotencyKey: key) else {
            throw TaskQueueError.taskNotFound
        }
        return .inserted(inserted)
    }

    public func claimNext(
        workerID: String,
        leaseDuration: TimeInterval = 60
    ) throws -> QueuedTask? {
        try database.execute("BEGIN IMMEDIATE")
        do {
            let now = clock()
            let select = try database.prepare(
                """
                SELECT id FROM tasks
                WHERE state = ? AND available_at <= ?
                ORDER BY priority ASC, created_at ASC
                LIMIT 1
                """
            )
            select.bind(1, TaskState.queued.rawValue)
            select.bind(2, now.timeIntervalSince1970)
            guard try select.step() == SQLITE_ROW,
                  let id = select.text(0)
            else {
                try database.execute("COMMIT")
                return nil
            }
            let update = try database.prepare(
                """
                UPDATE tasks
                SET state = ?, lease_owner = ?, lease_until = ?,
                    updated_at = ?, attempt_count = attempt_count + 1
                WHERE id = ? AND state = ?
                """
            )
            update.bind(1, TaskState.claimed.rawValue)
            update.bind(2, workerID)
            update.bind(3, now.addingTimeInterval(leaseDuration).timeIntervalSince1970)
            update.bind(4, now.timeIntervalSince1970)
            update.bind(5, id)
            update.bind(6, TaskState.queued.rawValue)
            _ = try update.step()
            guard database.changes == 1 else {
                try database.execute("ROLLBACK")
                return nil
            }
            guard let taskID = UUID(uuidString: id),
                  let claimed = try task(id: taskID)
            else {
                throw TaskQueueError.corruptPayload
            }
            try database.execute("COMMIT")
            return claimed
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    public func apply(taskID: UUID, event: TaskEvent) throws -> QueuedTask {
        guard let current = try task(id: taskID) else {
            throw TaskQueueError.taskNotFound
        }
        var machine = TaskStateMachine(state: current.state)
        try machine.apply(event)
        let now = clock()
        let statement = try database.prepare(
            """
            UPDATE tasks
            SET state = ?, updated_at = ?, lease_owner = NULL, lease_until = NULL
            WHERE id = ?
            """
        )
        statement.bind(1, machine.state.rawValue)
        statement.bind(2, now.timeIntervalSince1970)
        statement.bind(3, taskID.uuidString)
        _ = try statement.step()
        guard let updated = try task(id: taskID) else {
            throw TaskQueueError.taskNotFound
        }
        return updated
    }

    public func recoverAfterRestart() throws -> QueueRecoveryReport {
        let rows: [(String, String)] = try {
            let statement = try database.prepare(
                """
                SELECT id, state FROM tasks
                WHERE state IN (?, ?, ?, ?)
                """
            )
            statement.bind(1, TaskState.claimed.rawValue)
            statement.bind(2, TaskState.processing.rawValue)
            statement.bind(3, TaskState.replyGenerated.rawValue)
            statement.bind(4, TaskState.sendPending.rawValue)
            var output: [(String, String)] = []
            while try statement.step() == SQLITE_ROW {
                if let id = statement.text(0), let state = statement.text(1) {
                    output.append((id, state))
                }
            }
            return output
        }()

        var manualCount = 0
        var uncertainCount = 0
        for (id, stateValue) in rows {
            guard let state = TaskState(rawValue: stateValue) else {
                continue
            }
            let destination: TaskState
            switch state {
            case .sendPending:
                destination = .sendUncertain
                uncertainCount += 1
            default:
                destination = .manualReview
                manualCount += 1
            }
            let update = try database.prepare(
                """
                UPDATE tasks
                SET state = ?, updated_at = ?, lease_owner = NULL, lease_until = NULL,
                    last_error = ?
                WHERE id = ?
                """
            )
            update.bind(1, destination.rawValue)
            update.bind(2, clock().timeIntervalSince1970)
            update.bind(3, "Runner restart recovery: \(state.rawValue) -> \(destination.rawValue)")
            update.bind(4, id)
            _ = try update.step()
        }
        return QueueRecoveryReport(
            movedToManualReview: manualCount,
            markedSendUncertain: uncertainCount
        )
    }

    public func task(id: UUID) throws -> QueuedTask? {
        let statement = try database.prepare("\(Self.selectSQL) WHERE id = ? LIMIT 1")
        statement.bind(1, id.uuidString)
        guard try statement.step() == SQLITE_ROW else {
            return nil
        }
        return try decode(statement)
    }

    public func manualReviewTasks() throws -> [QueuedTask] {
        let statement = try database.prepare(
            "\(Self.selectSQL) WHERE state IN (?, ?) ORDER BY priority ASC, created_at ASC"
        )
        statement.bind(1, TaskState.manualReview.rawValue)
        statement.bind(2, TaskState.sendUncertain.rawValue)
        var output: [QueuedTask] = []
        while try statement.step() == SQLITE_ROW {
            output.append(try decode(statement))
        }
        return output
    }

    public func metrics() throws -> QueueMetrics {
        let statement = try database.prepare(
            "SELECT state, COUNT(*) FROM tasks GROUP BY state"
        )
        var counts: [String: Int] = [:]
        var total = 0
        while try statement.step() == SQLITE_ROW {
            guard let state = statement.text(0) else {
                continue
            }
            let count = statement.int(1)
            counts[state] = count
            total += count
        }
        return QueueMetrics(total: total, byState: counts)
    }

    private func task(byIdempotencyKey key: String) throws -> QueuedTask? {
        let statement = try database.prepare(
            "\(Self.selectSQL) WHERE idempotency_key = ? LIMIT 1"
        )
        statement.bind(1, key)
        guard try statement.step() == SQLITE_ROW else {
            return nil
        }
        return try decode(statement)
    }

    private func decode(_ statement: SQLiteStatement) throws -> QueuedTask {
        guard let idText = statement.text(0),
              let id = UUID(uuidString: idText),
              let eventID = statement.text(1),
              let idempotencyKey = statement.text(2),
              let platformText = statement.text(3),
              let platform = CommercePlatform(rawValue: platformText),
              let storeName = statement.text(4),
              let stateText = statement.text(5),
              let state = TaskState(rawValue: stateText),
              let payloadCipher = statement.data(14)
        else {
            throw TaskQueueError.corruptPayload
        }
        let payloadData = try cipher.decrypt(payloadCipher)
        let payload = try decoder.decode(TaskPayload.self, from: payloadData)
        let leaseUntil = statement.text(11)
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
        return QueuedTask(
            id: id,
            eventID: eventID,
            idempotencyKey: idempotencyKey,
            platform: platform,
            storeName: storeName,
            payload: payload,
            state: state,
            priority: TakeoverPriority(rawValue: statement.int(6)) ?? .normal,
            availableAt: Date(timeIntervalSince1970: statement.double(7)),
            createdAt: Date(timeIntervalSince1970: statement.double(8)),
            updatedAt: Date(timeIntervalSince1970: statement.double(9)),
            leaseOwner: statement.text(10),
            leaseUntil: leaseUntil,
            attemptCount: statement.int(12),
            lastError: statement.text(13)
        )
    }

    private static let selectSQL = """
    SELECT id, event_id, idempotency_key, platform, store_name, state,
           priority, available_at, created_at, updated_at, lease_owner,
           lease_until, attempt_count, last_error, encrypted_payload
    FROM tasks
    """

    private static func createSchema(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                event_id TEXT NOT NULL,
                idempotency_key TEXT NOT NULL UNIQUE,
                platform TEXT NOT NULL,
                store_name TEXT NOT NULL,
                state TEXT NOT NULL,
                priority INTEGER NOT NULL,
                available_at REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                lease_owner TEXT,
                lease_until REAL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                encrypted_payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tasks_claim
                ON tasks(state, available_at, priority, created_at);
            INSERT OR IGNORE INTO schema_migrations(version, applied_at)
                VALUES(1, strftime('%s','now'));
            """
        )
    }
}
