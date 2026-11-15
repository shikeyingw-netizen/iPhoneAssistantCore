import Foundation

public enum TaskTransitionError: Error, Equatable, CustomStringConvertible {
    case invalid(from: TaskState, event: TaskEvent)
    case uncertainSendCannotBeRetried

    public var description: String {
        switch self {
        case let .invalid(from, event):
            return "Invalid task transition from \(from.rawValue) via \(event.rawValue)"
        case .uncertainSendCannotBeRetried:
            return "An uncertain send must be reconciled or escalated to a human; it cannot be retried blindly"
        }
    }
}

public struct TaskTransition: Equatable, Sendable {
    public let event: TaskEvent
    public let state: TaskState

    public init(event: TaskEvent, state: TaskState) {
        self.event = event
        self.state = state
    }
}

public struct TaskStateMachine: Sendable {
    public private(set) var state: TaskState
    public private(set) var history: [TaskTransition]

    public init(state: TaskState = .queued) {
        self.state = state
        self.history = []
    }

    public mutating func apply(_ event: TaskEvent) throws {
        if state == .sendUncertain && event == .requestSend {
            throw TaskTransitionError.uncertainSendCannotBeRetried
        }
        guard let next = Self.transition(state: state, event: event) else {
            throw TaskTransitionError.invalid(from: state, event: event)
        }
        state = next
        history.append(TaskTransition(event: event, state: next))
    }

    public static func transition(
        state: TaskState,
        event: TaskEvent
    ) -> TaskState? {
        switch (state, event) {
        case (.queued, .claim):
            return .claimed
        case (.claimed, .startProcessing):
            return .processing
        case (.processing, .generateReply):
            return .replyGenerated
        case (.replyGenerated, .requestSend):
            return .sendPending
        case (.sendPending, .sendVerified):
            return .sentVerified
        case (.sendPending, .sendNotVerified):
            return .sendUncertain
        case (.sendUncertain, .sendVerified):
            return .sentVerified
        case (.sendUncertain, .escalateToHuman):
            return .manualReview
        case (_, .escalateToHuman):
            return .manualReview
        case (_, .fail) where state != .sentVerified:
            return .failed
        case (.failed, .resolveManually), (.manualReview, .resolveManually):
            return .claimed
        default:
            return nil
        }
    }

    public var requiresHumanReconciliation: Bool {
        state == .sendUncertain || state == .manualReview || state == .failed
    }

    public var isTerminalSuccess: Bool {
        state == .sentVerified
    }
}
