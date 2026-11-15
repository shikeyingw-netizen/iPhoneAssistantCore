import Foundation

public actor ManualTakeoverCenter {
    private let store: TakeoverStateStore?
    private let clock: @Sendable () -> Date
    private var tasks: [UUID: TakeoverTask] = [:]
    private var knowledge: [KnowledgeEntry] = []
    private var automaticRepliesPaused = false
    private var controlAuditTrail: [TakeoverAuditEvent] = []

    public init(
        store: TakeoverStateStore? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.clock = clock
    }

    public func restore() async throws {
        guard let store else { return }
        let snapshot = try await store.load()
        tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        knowledge = snapshot.knowledge
        automaticRepliesPaused = snapshot.automaticRepliesPaused
        controlAuditTrail = snapshot.controlAuditTrail
    }

    public func submit(_ task: TakeoverTask) async throws -> TakeoverSubmission {
        var stored = task
        stored.updatedAt = clock()
        tasks[stored.id] = stored
        try await persist()
        let notification = TakeoverNotificationRequest(
            taskID: stored.id,
            title: "\(stored.source.displayName)需要人工处理",
            body: "\(stored.storeName)：\(PIISanitizer.sanitize(stored.buyerQuestion))"
        )
        return TakeoverSubmission(task: stored, notification: notification)
    }

    public func pendingTasks() -> [TakeoverTask] {
        tasks.values
            .filter { $0.status == .pendingReview || $0.status == .sendUncertain }
            .sorted {
                if $0.priority != $1.priority {
                    return $0.priority < $1.priority
                }
                return $0.createdAt < $1.createdAt
            }
    }

    public func task(id: UUID) -> TakeoverTask? {
        tasks[id]
    }

    public func editReply(taskID: UUID, reply: String) async throws {
        guard var task = tasks[taskID] else {
            throw TakeoverError.taskNotFound
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TakeoverError.emptyReply
        }
        let now = clock()
        task.editedReply = trimmed
        task.updatedAt = now
        task.auditTrail.append(
            TakeoverAuditEvent(
                kind: .suggestionEdited,
                at: now,
                actor: "user"
            )
        )
        tasks[taskID] = task
        try await persist()
    }

    public func approve(taskID: UUID) async throws {
        guard var task = tasks[taskID] else {
            throw TakeoverError.taskNotFound
        }
        guard task.status == .pendingReview else {
            throw TakeoverError.invalidState
        }
        guard !task.editedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TakeoverError.emptyReply
        }
        let now = clock()
        task.status = .approvedToSend
        task.approvedAt = now
        task.updatedAt = now
        task.auditTrail.append(
            TakeoverAuditEvent(kind: .approved, at: now, actor: "user")
        )
        tasks[taskID] = task
        try await persist()
    }

    public func reject(taskID: UUID, reason: String = "") async throws {
        guard var task = tasks[taskID] else {
            throw TakeoverError.taskNotFound
        }
        guard task.status == .pendingReview else {
            throw TakeoverError.invalidState
        }
        let now = clock()
        task.status = .rejected
        task.updatedAt = now
        task.auditTrail.append(
            TakeoverAuditEvent(
                kind: .rejected,
                at: now,
                actor: "user",
                note: reason
            )
        )
        tasks[taskID] = task
        try await persist()
    }

    public func markSendUncertain(taskID: UUID) async throws {
        guard var task = tasks[taskID] else {
            throw TakeoverError.taskNotFound
        }
        guard task.status == .approvedToSend else {
            throw TakeoverError.invalidState
        }
        let now = clock()
        task.status = .sendUncertain
        task.updatedAt = now
        task.auditTrail.append(
            TakeoverAuditEvent(kind: .sendUncertain, at: now, actor: "system")
        )
        tasks[taskID] = task
        try await persist()
    }

    public func markSentVerified(taskID: UUID) async throws {
        guard var task = tasks[taskID] else {
            throw TakeoverError.taskNotFound
        }
        guard task.status == .approvedToSend || task.status == .sendUncertain else {
            throw TakeoverError.invalidState
        }
        let now = clock()
        task.status = .sentVerified
        task.updatedAt = now
        task.auditTrail.append(
            TakeoverAuditEvent(kind: .sentVerified, at: now, actor: "system")
        )
        tasks[taskID] = task
        try await persist()
    }

    public func pauseAllAutomaticReplies() async throws {
        automaticRepliesPaused = true
        controlAuditTrail.append(
            TakeoverAuditEvent(
                kind: .automationPaused,
                at: clock(),
                actor: "user"
            )
        )
        try await persist()
    }

    public func resumeAutomaticReplies() async throws {
        automaticRepliesPaused = false
        controlAuditTrail.append(
            TakeoverAuditEvent(
                kind: .automationResumed,
                at: clock(),
                actor: "user"
            )
        )
        try await persist()
    }

    public var isAutomationPaused: Bool {
        automaticRepliesPaused
    }

    public func canSend(taskID: UUID) -> Bool {
        guard !automaticRepliesPaused,
              let task = tasks[taskID]
        else {
            return false
        }
        return task.status == .approvedToSend && task.approvedAt != nil
    }

    public func addKnowledge(
        taskID: UUID,
        answer: String,
        source: KnowledgeSource
    ) async throws -> KnowledgeEntry {
        guard let task = tasks[taskID] else {
            throw TakeoverError.taskNotFound
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TakeoverError.emptyReply
        }
        let now = clock()
        let normalizedQuestion = Self.normalize(task.buyerQuestion)
        if let index = knowledge.firstIndex(where: {
            Self.normalize($0.question) == normalizedQuestion
        }) {
            var existing = knowledge[index]
            existing.answer = trimmed
            existing.updatedAt = now
            existing.version += 1
            knowledge[index] = existing
            try await persist()
            return existing
        }

        let entry = KnowledgeEntry(
            question: task.buyerQuestion,
            answer: trimmed,
            sourceTaskID: taskID,
            source: source,
            createdAt: now
        )
        knowledge.append(entry)
        try await persist()
        return entry
    }

    public func knowledgeSuggestions(for question: String) -> [KnowledgeSuggestion] {
        let normalized = Self.normalize(question)
        return knowledge
            .filter { Self.normalize($0.question) == normalized }
            .map {
                KnowledgeSuggestion(
                    entry: $0,
                    requiresManualReview: true,
                    reason: "仅命中完全相同的问题；仍需人工确认后才可使用"
                )
            }
    }

    public func snapshot() -> TakeoverSnapshot {
        TakeoverSnapshot(
            tasks: tasks.values.sorted { $0.createdAt < $1.createdAt },
            knowledge: knowledge,
            automaticRepliesPaused: automaticRepliesPaused,
            controlAuditTrail: controlAuditTrail
        )
    }

    private func persist() async throws {
        guard let store else { return }
        try await store.save(snapshot())
    }

    private static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "？", with: "?")
            .replacingOccurrences(of: "！", with: "!")
            .replacingOccurrences(of: "。", with: ".")
            .lowercased()
    }
}
