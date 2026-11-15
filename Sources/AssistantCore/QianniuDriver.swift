import Foundation

public enum QianniuSurface: Equatable, Sendable {
    case directChat(customer: String)
    case unknown
}

public enum QianniuPageParser {
    public static func parse(_ snapshot: AccessibilitySnapshot) -> QianniuSurface {
        let hasBack = snapshot.nodes.contains {
            $0.kind == "Button" && $0.label == "back"
        }
        guard hasBack, input(in: snapshot) != nil else {
            return .unknown
        }
        return .directChat(customer: customerName(snapshot))
    }

    public static func input(
        in snapshot: AccessibilitySnapshot
    ) -> AccessibilityNode? {
        snapshot.nodes
            .filter {
                $0.kind == "TextView"
                    && $0.width >= 100
                    && $0.y >= 700
            }
            .max(by: { $0.y < $1.y })
    }

    private static func customerName(_ snapshot: AccessibilitySnapshot) -> String {
        snapshot.nodes
            .filter {
                $0.kind == "Button"
                    && $0.x >= 40
                    && $0.x < 220
                    && $0.y < 130
                    && !$0.label.isEmpty
                    && $0.label != "back"
                    && $0.label != "mine_circle"
                    && !$0.label.hasPrefix("http")
            }
            .min(by: {
                if $0.y == $1.y {
                    return $0.x < $1.x
                }
                return $0.y < $1.y
            })?
            .label ?? "未知客户"
    }
}

public enum QianniuDriverError: Error, Equatable {
    case notDirectChat
    case replyInputNotFound
    case typedReplyNotVerified
    case sendButtonNotFound
    case emptyReply
}

public enum QianniuSendReceipt: Equatable, Sendable {
    case sentVerified
    case sendUncertain(reason: String)
}

public actor QianniuDriver {
    public static let bundleID = "com.taobao.sellerplatform"

    private let bridge: any AppUIBridge

    public init(bridge: any AppUIBridge) {
        self.bridge = bridge
    }

    public func inspect() async throws -> QianniuSurface {
        let snapshot = try await bridge.snapshot(bundleID: Self.bundleID)
        return QianniuPageParser.parse(snapshot)
    }

    public func prepareReply(_ reply: String) async throws {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw QianniuDriverError.emptyReply
        }

        for attempt in 0..<2 {
            let snapshot = try await bridge.snapshot(bundleID: Self.bundleID)
            guard case .directChat = QianniuPageParser.parse(snapshot) else {
                throw QianniuDriverError.notDirectChat
            }
            guard let input = QianniuPageParser.input(in: snapshot) else {
                throw QianniuDriverError.replyInputNotFound
            }

            // Qianniu's first tap often only activates the custom composer;
            // the keyboard and text view become ready a moment later.
            try await bridge.tap(x: input.centerX, y: input.centerY)
            try await bridge.wait(seconds: 0.7)
            let focused = try await bridge.snapshot(bundleID: Self.bundleID)
            guard case .directChat = QianniuPageParser.parse(focused),
                  let focusedInput = QianniuPageParser.input(in: focused)
            else {
                throw QianniuDriverError.replyInputNotFound
            }
            try await bridge.type(
                text: trimmed,
                x: focusedInput.centerX,
                y: focusedInput.centerY,
                clear: true
            )
            let typed = try await bridge.snapshot(bundleID: Self.bundleID)
            if typed.nodes.contains(where: {
                $0.kind == "TextView" && $0.value == trimmed
            }) {
                return
            }
            if let current = QianniuPageParser.input(in: typed),
               !current.value.isEmpty {
                // Anything already present is ambiguous. Never append or
                // overwrite a partial draft automatically.
                throw QianniuDriverError.typedReplyNotVerified
            }
            if attempt == 0 {
                try await bridge.wait(seconds: 0.4)
            }
        }
        throw QianniuDriverError.typedReplyNotVerified
    }

    public func sendPreparedReply(
        _ reply: String
    ) async throws -> QianniuSendReceipt {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = try await bridge.snapshot(bundleID: Self.bundleID)
        guard case .directChat = QianniuPageParser.parse(before) else {
            throw QianniuDriverError.notDirectChat
        }
        guard before.nodes.contains(where: {
            $0.kind == "TextView" && $0.value == trimmed
        }) else {
            throw QianniuDriverError.typedReplyNotVerified
        }
        let beforeCount = messageOccurrences(of: trimmed, in: before)
        if keyboardIsVisible(before) {
            try await bridge.tap(x: 354, y: 702)
        } else {
            guard let send = sendButton(in: before) else {
                throw QianniuDriverError.sendButtonNotFound
            }
            try await bridge.tap(x: send.centerX, y: send.centerY)
        }
        let after = try await bridge.snapshot(bundleID: Self.bundleID)
        let afterCount = messageOccurrences(of: trimmed, in: after)
        let inputStillContainsReply = after.nodes.contains {
            $0.kind == "TextView" && $0.value == trimmed
        }
        if afterCount > beforeCount && !inputStillContainsReply {
            return .sentVerified
        }
        return .sendUncertain(
            reason: "Qianniu reply was not uniquely verified as sent"
        )
    }

    private func sendButton(
        in snapshot: AccessibilitySnapshot
    ) -> AccessibilityNode? {
        snapshot.nodes
            .filter {
                $0.kind == "Button"
                    && $0.x >= 300
                    && $0.y >= 730
                    && $0.width >= 20
                    && $0.width <= 56
                    && $0.height >= 20
                    && $0.height <= 56
            }
            .max(by: { $0.x < $1.x })
    }

    private func keyboardIsVisible(
        _ snapshot: AccessibilitySnapshot
    ) -> Bool {
        snapshot.source.contains("Keyboard,")
            || snapshot.source.contains("隐藏输入法")
            || snapshot.source.contains("数字键盘")
    }

    private func messageOccurrences(
        of reply: String,
        in snapshot: AccessibilitySnapshot
    ) -> Int {
        snapshot.nodes.filter {
            ($0.kind == "Other" || $0.kind == "StaticText")
                && $0.label == reply
        }.count
    }
}
