import Foundation

public enum CommercePlatform: String, Codable, CaseIterable, Sendable {
    case pinduoduo
    case qianniu

    public var displayName: String {
        switch self {
        case .pinduoduo:
            return "拼多多"
        case .qianniu:
            return "千牛"
        }
    }
}

public enum MessageSide: String, Codable, Sendable {
    case customer
    case merchant
    case system
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public let side: MessageSide
    public let text: String
    public let observedAt: Date

    public init(side: MessageSide, text: String, observedAt: Date = Date()) {
        self.side = side
        self.text = text
        self.observedAt = observedAt
    }
}

public struct ConversationContext: Codable, Equatable, Sendable {
    public let platform: CommercePlatform
    public let storeName: String
    public let customerName: String
    public let messages: [ChatMessage]

    public init(
        platform: CommercePlatform,
        storeName: String,
        customerName: String,
        messages: [ChatMessage]
    ) {
        self.platform = platform
        self.storeName = storeName
        self.customerName = customerName
        self.messages = messages
    }

    public var latestCustomerMessage: String? {
        messages.last(where: { $0.side == .customer })?.text
    }
}

public enum RiskCategory: String, Codable, Sendable {
    case normal
    case refund
    case addressChange
    case compensation
    case complaintOrLegal
    case pricingChange
    case productSafety
    case orderInterception
    case platformNotice
    case emptyMessage
}

public struct RiskAssessment: Equatable, Sendable {
    public let category: RiskCategory
    public let requiresHumanReview: Bool
    public let safeHoldingReply: String?
    public let reasons: [String]

    public init(
        category: RiskCategory,
        requiresHumanReview: Bool,
        safeHoldingReply: String?,
        reasons: [String]
    ) {
        self.category = category
        self.requiresHumanReview = requiresHumanReview
        self.safeHoldingReply = safeHoldingReply
        self.reasons = reasons
    }

    public var shouldAutoReply: Bool {
        category != .platformNotice
            && category != .emptyMessage
            && !requiresHumanReview
    }
}

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case queued
    case claimed
    case processing
    case replyGenerated
    case sendPending
    case sendUncertain
    case sentVerified
    case manualReview
    case failed
}

public enum TaskEvent: String, Codable, Sendable {
    case claim
    case startProcessing
    case generateReply
    case requestSend
    case sendVerified
    case sendNotVerified
    case escalateToHuman
    case fail
    case resolveManually
}

public enum Courier: String, Codable, CaseIterable, Sendable {
    case sto
    case jnt
}

public enum OrderStatus: String, Codable, Sendable {
    case paid
    case shipped
    case signed
    case cancelled
    case unknown
}

public enum LogisticsAction: String, Codable, Sendable {
    case intercept
    case addressChange
}
