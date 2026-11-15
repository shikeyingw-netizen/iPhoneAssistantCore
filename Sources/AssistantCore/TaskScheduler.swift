import Foundation

public enum TaskSchedulerResult: Equatable, Sendable {
    case idle
    case paused
    case completed(taskID: UUID, finalState: TaskState)
    case failedToManualReview(taskID: UUID, error: String)
}

public actor TaskScheduler {
    private let queue: SQLiteTaskQueue
    private let workerID: String
    private var automaticRepliesPaused = false

    public init(queue: SQLiteTaskQueue, workerID: String = UUID().uuidString) {
        self.queue = queue
        self.workerID = workerID
    }

    public func setAutomaticRepliesPaused(_ paused: Bool) {
        automaticRepliesPaused = paused
    }

    public var isPaused: Bool {
        automaticRepliesPaused
    }

    public func recoverAfterRestart() async throws -> QueueRecoveryReport {
        try await queue.recoverAfterRestart()
    }

    public func processNext(
        leaseDuration: TimeInterval = 60,
        handler: @escaping @Sendable (QueuedTask) async throws -> [TaskEvent]
    ) async throws -> TaskSchedulerResult {
        if automaticRepliesPaused {
            return .paused
        }
        guard let task = try await queue.claimNext(
            workerID: workerID,
            leaseDuration: leaseDuration
        ) else {
            return .idle
        }

        do {
            let events = try await handler(task)
            if events.isEmpty {
                _ = try await queue.apply(taskID: task.id, event: .escalateToHuman)
                return .failedToManualReview(
                    taskID: task.id,
                    error: "worker returned no state transitions"
                )
            }
            var latest = task
            for event in events {
                latest = try await queue.apply(taskID: task.id, event: event)
            }
            return .completed(taskID: task.id, finalState: latest.state)
        } catch {
            _ = try? await queue.apply(taskID: task.id, event: .escalateToHuman)
            return .failedToManualReview(
                taskID: task.id,
                error: String(describing: error)
            )
        }
    }

    public func processAvailable(
        maximumTasks: Int = 20,
        leaseDuration: TimeInterval = 60,
        handler: @escaping @Sendable (QueuedTask) async throws -> [TaskEvent]
    ) async throws -> [TaskSchedulerResult] {
        var results: [TaskSchedulerResult] = []
        for _ in 0..<maximumTasks {
            let result = try await processNext(
                leaseDuration: leaseDuration,
                handler: handler
            )
            if result == .idle || result == .paused {
                results.append(result)
                break
            }
            results.append(result)
        }
        return results
    }
}
