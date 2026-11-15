import Foundation

public struct QueueConversationMessage: Codable, Equatable, Sendable {
    public let side: MessageSide
    public let text: String
    public let observedAt: Date

    public init(side: MessageSide, text: String, observedAt: Date) {
        self.side = side
        self.text = text
        self.observedAt = observedAt
    }
}

public struct QueueOrderInfo: Codable, Equatable, Sendable {
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

public struct TaskPayload: Codable, Equatable, Sendable {
    public let notificationKey: String
    public let customerName: String
    public let buyerQuestion: String
    public let conversation: [QueueConversationMessage]
    public let orderInfo: QueueOrderInfo?
    public let riskCategory: RiskCategory
    public let aiReason: String
    public let suggestedReply: String

    public init(
        notificationKey: String,
        customerName: String,
        buyerQuestion: String,
        conversation: [QueueConversationMessage],
        orderInfo: QueueOrderInfo?,
        riskCategory: RiskCategory,
        aiReason: String,
        suggestedReply: String
    ) {
        self.notificationKey = notificationKey
        self.customerName = customerName
        self.buyerQuestion = buyerQuestion
        self.conversation = conversation
        self.orderInfo = orderInfo
        self.riskCategory = riskCategory
        self.aiReason = aiReason
        self.suggestedReply = suggestedReply
    }
}

public struct QueueTaskInput: Equatable, Sendable {
    public let id: UUID
    public let eventID: String
    public let idempotencyKey: String
    public let platform: CommercePlatform
    public let storeName: String
    public let payload: TaskPayload
    public let priority: TakeoverPriority
    public let availableAt: Date
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        eventID: String,
        idempotencyKey: String,
        platform: CommercePlatform,
        storeName: String,
        payload: TaskPayload,
        priority: TakeoverPriority = .normal,
        availableAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.eventID = eventID
        self.idempotencyKey = idempotencyKey
        self.platform = platform
        self.storeName = storeName
        self.payload = payload
        self.priority = priority
        self.availableAt = availableAt
        self.createdAt = createdAt
    }
}

public struct QueuedTask: Equatable, Sendable {
    public let id: UUID
    public let eventID: String
    public let idempotencyKey: String
    public let platform: CommercePlatform
    public let storeName: String
    public let payload: TaskPayload
    public let state: TaskState
    public let priority: TakeoverPriority
    public let availableAt: Date
    public let createdAt: Date
    public let updatedAt: Date
    public let leaseOwner: String?
    public let leaseUntil: Date?
    public let attemptCount: Int
    public let lastError: String?

    public init(
        id: UUID,
        eventID: String,
        idempotencyKey: String,
        platform: CommercePlatform,
        storeName: String,
        payload: TaskPayload,
        state: TaskState,
        priority: TakeoverPriority,
        availableAt: Date,
        createdAt: Date,
        updatedAt: Date,
        leaseOwner: String?,
        leaseUntil: Date?,
        attemptCount: Int,
        lastError: String?
    ) {
        self.id = id
        self.eventID = eventID
        self.idempotencyKey = idempotencyKey
        self.platform = platform
        self.storeName = storeName
        self.payload = payload
        self.state = state
        self.priority = priority
        self.availableAt = availableAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.leaseOwner = leaseOwner
        self.leaseUntil = leaseUntil
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

public enum QueueEnqueueResult: Equatable, Sendable {
    case inserted(QueuedTask)
    case duplicate(QueuedTask)
}

public struct QueueRecoveryReport: Codable, Equatable, Sendable {
    public let movedToManualReview: Int
    public let markedSendUncertain: Int

    public init(movedToManualReview: Int, markedSendUncertain: Int) {
        self.movedToManualReview = movedToManualReview
        self.markedSendUncertain = markedSendUncertain
    }
}

public struct QueueMetrics: Codable, Equatable, Sendable {
    public let total: Int
    public let byState: [String: Int]

    public init(total: Int, byState: [String: Int]) {
        self.total = total
        self.byState = byState
    }
}
