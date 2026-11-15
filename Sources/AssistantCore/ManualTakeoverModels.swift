import Foundation

public enum TakeoverSource: String, Codable, CaseIterable, Sendable {
    case pinduoduo
    case qianniu
    case wechatLogistics

    public var displayName: String {
        switch self {
        case .pinduoduo:
            return "拼多多"
        case .qianniu:
            return "千牛"
        case .wechatLogistics:
            return "微信物流"
        }
    }
}

public enum TakeoverPriority: Int, Codable, Comparable, Sendable {
    case high = 0
    case normal = 1
    case low = 2

    public static func < (lhs: TakeoverPriority, rhs: TakeoverPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum TakeoverStatus: String, Codable, Sendable {
    case pendingReview
    case approvedToSend
    case rejected
    case sendUncertain
    case sentVerified
    case resolvedWithoutSend
}

public enum TakeoverAuditKind: String, Codable, Sendable {
    case taskCreated
    case suggestionEdited
    case approved
    case rejected
    case sendUncertain
    case sentVerified
    case automationPaused
    case automationResumed
    case knowledgeCreated
    case knowledgeUpdated
}

public struct TakeoverAuditEvent: Codable, Equatable, Sendable {
    public let kind: TakeoverAuditKind
    public let at: Date
    public let actor: String
    public let note: String

    public init(kind: TakeoverAuditKind, at: Date, actor: String, note: String = "") {
        self.kind = kind
        self.at = at
        self.actor = actor
        self.note = note
    }
}

public struct TakeoverOrderInfo: Codable, Equatable, Sendable {
    public let orderID: String
    public let status: String
    public let carrier: String
    public let trackingNumber: String

    public init(
        orderID: String,
        status: String,
        carrier: String,
        trackingNumber: String
    ) {
        self.orderID = orderID
        self.status = status
        self.carrier = carrier
        self.trackingNumber = trackingNumber
    }
}

public struct TakeoverTask: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let source: TakeoverSource
    public let storeName: String
    public let buyerName: String
    public let buyerQuestion: String
    public let originalConversation: [ChatMessage]
    public let orderInfo: TakeoverOrderInfo?
    public let aiReason: String
    public let aiSuggestedReply: String
    public let isHighRisk: Bool
    public var editedReply: String
    public var status: TakeoverStatus
    public var priority: TakeoverPriority
    public let createdAt: Date
    public var updatedAt: Date
    public var approvedAt: Date?
    public var auditTrail: [TakeoverAuditEvent]

    public init(
        id: UUID = UUID(),
        source: TakeoverSource,
        storeName: String,
        buyerName: String,
        buyerQuestion: String,
        originalConversation: [ChatMessage],
        orderInfo: TakeoverOrderInfo?,
        aiReason: String,
        aiSuggestedReply: String,
        isHighRisk: Bool,
        priority: TakeoverPriority = .high,
        createdAt: Date
    ) {
        self.id = id
        self.source = source
        self.storeName = storeName
        self.buyerName = buyerName
        self.buyerQuestion = buyerQuestion
        self.originalConversation = originalConversation
        self.orderInfo = orderInfo
        self.aiReason = aiReason
        self.aiSuggestedReply = aiSuggestedReply
        self.isHighRisk = isHighRisk
        self.editedReply = aiSuggestedReply
        self.status = .pendingReview
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.approvedAt = nil
        self.auditTrail = [
            TakeoverAuditEvent(
                kind: .taskCreated,
                at: createdAt,
                actor: "system",
                note: aiReason
            )
        ]
    }
}

public enum KnowledgeSource: String, Codable, Sendable {
    case manualApproval
    case manualClarification
}

public struct KnowledgeEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let question: String
    public var answer: String
    public let sourceTaskID: UUID
    public let source: KnowledgeSource
    public let createdAt: Date
    public var updatedAt: Date
    public var version: Int

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        sourceTaskID: UUID,
        source: KnowledgeSource,
        createdAt: Date
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.sourceTaskID = sourceTaskID
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.version = 1
    }
}

public struct KnowledgeSuggestion: Equatable, Sendable {
    public let entry: KnowledgeEntry
    public let requiresManualReview: Bool
    public let reason: String
}

public struct TakeoverNotificationRequest: Equatable, Sendable {
    public let taskID: UUID
    public let title: String
    public let body: String

    public init(taskID: UUID, title: String, body: String) {
        self.taskID = taskID
        self.title = title
        self.body = body
    }
}

public struct TakeoverSubmission: Equatable, Sendable {
    public let task: TakeoverTask
    public let notification: TakeoverNotificationRequest
}

public struct TakeoverSnapshot: Codable, Equatable, Sendable {
    public var tasks: [TakeoverTask]
    public var knowledge: [KnowledgeEntry]
    public var automaticRepliesPaused: Bool
    public var controlAuditTrail: [TakeoverAuditEvent]

    public init(
        tasks: [TakeoverTask] = [],
        knowledge: [KnowledgeEntry] = [],
        automaticRepliesPaused: Bool = false,
        controlAuditTrail: [TakeoverAuditEvent] = []
    ) {
        self.tasks = tasks
        self.knowledge = knowledge
        self.automaticRepliesPaused = automaticRepliesPaused
        self.controlAuditTrail = controlAuditTrail
    }
}

public protocol TakeoverStateStore: Sendable {
    func load() async throws -> TakeoverSnapshot
    func save(_ snapshot: TakeoverSnapshot) async throws
}

public enum TakeoverError: Error, Equatable {
    case taskNotFound
    case emptyReply
    case invalidState
    case sendUncertainRequiresReconciliation
}
