import Foundation

public enum WeChatLogisticsStatus: String, Codable, Equatable, Sendable {
    case awaitingConfirmation
    case approved
    case sendUncertain
    case sentVerified
}

public struct WeChatLogisticsDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let fingerprint: String
    public let action: LogisticsAction
    public let groupName: String
    public let message: String
    public let createdAt: Date
    public var status: WeChatLogisticsStatus
    public var approvedAt: Date?
    public var approvedBy: String?

    public init(
        id: UUID = UUID(),
        fingerprint: String,
        action: LogisticsAction,
        groupName: String,
        message: String,
        createdAt: Date
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.action = action
        self.groupName = groupName
        self.message = message
        self.createdAt = createdAt
        self.status = .awaitingConfirmation
        self.approvedAt = nil
        self.approvedBy = nil
    }
}

public struct ApprovedWeChatLogisticsMessage: Equatable, Sendable {
    public let draftID: UUID
    public let groupName: String
    public let message: String
    public let fingerprint: String

    init(draft: WeChatLogisticsDraft) {
        self.draftID = draft.id
        self.groupName = draft.groupName
        self.message = draft.message
        self.fingerprint = draft.fingerprint
    }
}

public enum WeChatLogisticsError: Error, Equatable {
    case blocked(reason: String, missingFields: [String])
    case draftNotFound
    case invalidState
}

public actor WeChatLogisticsCoordinator {
    private let policy: LogisticsPolicy
    private let clock: @Sendable () -> Date
    private var drafts: [UUID: WeChatLogisticsDraft] = [:]
    private var idsByFingerprint: [String: UUID] = [:]

    public init(
        policy: LogisticsPolicy,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.clock = clock
    }

    public func prepareIntercept(
        order: OrderSnapshot
    ) throws -> WeChatLogisticsDraft {
        let decision = policy.intercept(order)
        guard decision.allowed else {
            throw WeChatLogisticsError.blocked(
                reason: decision.reason,
                missingFields: decision.missingFields
            )
        }
        return draft(
            order: order,
            action: .intercept,
            groupName: decision.groupName,
            message: decision.courierMessage
        )
    }

    public func prepareAddressChange(
        order: OrderSnapshot,
        address: NewRecipientAddress
    ) throws -> WeChatLogisticsDraft {
        let decision = policy.changeAddress(order, address: address)
        guard decision.allowed else {
            throw WeChatLogisticsError.blocked(
                reason: decision.reason,
                missingFields: decision.missingFields
            )
        }
        return draft(
            order: order,
            action: .addressChange,
            groupName: decision.groupName,
            message: decision.courierMessage
        )
    }

    public func approve(
        draftID: UUID,
        approvedBy: String
    ) throws -> ApprovedWeChatLogisticsMessage {
        guard var draft = drafts[draftID] else {
            throw WeChatLogisticsError.draftNotFound
        }
        guard draft.status == .awaitingConfirmation else {
            throw WeChatLogisticsError.invalidState
        }
        let actor = approvedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actor.isEmpty else {
            throw WeChatLogisticsError.invalidState
        }
        draft.status = .approved
        draft.approvedAt = clock()
        draft.approvedBy = actor
        drafts[draftID] = draft
        return ApprovedWeChatLogisticsMessage(draft: draft)
    }

    public func markSendUncertain(draftID: UUID) throws {
        guard var draft = drafts[draftID] else {
            throw WeChatLogisticsError.draftNotFound
        }
        guard draft.status == .approved else {
            throw WeChatLogisticsError.invalidState
        }
        draft.status = .sendUncertain
        drafts[draftID] = draft
    }

    public func markSentVerified(draftID: UUID) throws {
        guard var draft = drafts[draftID] else {
            throw WeChatLogisticsError.draftNotFound
        }
        guard draft.status == .approved || draft.status == .sendUncertain else {
            throw WeChatLogisticsError.invalidState
        }
        draft.status = .sentVerified
        drafts[draftID] = draft
    }

    public func draft(id: UUID) -> WeChatLogisticsDraft? {
        drafts[id]
    }

    private func draft(
        order: OrderSnapshot,
        action: LogisticsAction,
        groupName: String,
        message: String
    ) -> WeChatLogisticsDraft {
        let logisticsKey = policy.fingerprint(order: order, action: action)
        let fingerprint = String(
            StableIdentifier.hexDigest(logisticsKey, message).prefix(24)
        )
        if let existingID = idsByFingerprint[fingerprint],
           let existing = drafts[existingID] {
            return existing
        }
        let value = WeChatLogisticsDraft(
            fingerprint: fingerprint,
            action: action,
            groupName: groupName,
            message: message,
            createdAt: clock()
        )
        drafts[value.id] = value
        idsByFingerprint[fingerprint] = value.id
        return value
    }
}
