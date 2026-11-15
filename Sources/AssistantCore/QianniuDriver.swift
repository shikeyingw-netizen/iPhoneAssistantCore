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
                    && $0.y >= 300
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
    case keyboardLanguageNotVerified
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
    private static let languageKey = CGPoint(x: 42, y: 810)

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

        let snapshot = try await bridge.snapshot(bundleID: Self.bundleID)
        guard case .directChat = QianniuPageParser.parse(snapshot) else {
            throw QianniuDriverError.notDirectChat
        }
        guard let input = QianniuPageParser.input(in: snapshot) else {
            throw QianniuDriverError.replyInputNotFound
        }

        // Qianniu's first tap often only activates the custom composer.
        try await bridge.tap(x: input.centerX, y: input.centerY)
        try await bridge.wait(seconds: 0.7)
        var focused = try await bridge.snapshot(bundleID: Self.bundleID)
        guard case .directChat = QianniuPageParser.parse(focused),
              let focusedInput = QianniuPageParser.input(in: focused)
        else {
            throw QianniuDriverError.replyInputNotFound
        }
        guard focusedInput.value.isEmpty else {
            throw QianniuDriverError.typedReplyNotVerified
        }

        // XCTest's direct text injection works with Qianniu's English
        // keyboard, while its Chinese nine-key keyboard resigns focus and
        // drops the text. Select English only for the insertion, then restore
        // the Chinese keyboard so the established send-button coordinates
        // remain valid.
        try await selectKeyboard(.english, snapshot: focused)
        try await bridge.type(
            text: trimmed,
            x: focusedInput.centerX,
            y: focusedInput.centerY,
            clear: false
        )
        let typed = try await bridge.snapshot(bundleID: Self.bundleID)
        guard let typedInput = QianniuPageParser.input(in: typed),
              typedInput.value == trimmed
        else {
            throw QianniuDriverError.typedReplyNotVerified
        }

        // Typing dismisses Qianniu's software keyboard. Reopen it without
        // changing the text, then restore the Chinese layout.
        try await bridge.tap(
            x: typedInput.centerX,
            y: typedInput.centerY
        )
        try await bridge.wait(seconds: 0.4)
        focused = try await bridge.snapshot(bundleID: Self.bundleID)
        guard let reopenedInput = QianniuPageParser.input(in: focused),
              reopenedInput.value == trimmed
        else {
            throw QianniuDriverError.typedReplyNotVerified
        }
        try await selectKeyboard(.chinese, snapshot: focused)
        let ready = try await bridge.snapshot(bundleID: Self.bundleID)
        guard case .directChat = QianniuPageParser.parse(ready),
              let readyInput = QianniuPageParser.input(in: ready),
              readyInput.value == trimmed,
              keyboardLanguage(in: ready) == .chinese
        else {
            throw QianniuDriverError.keyboardLanguageNotVerified
        }
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
        if let send = keyboardSendButton(in: before) {
            try await bridge.tap(x: send.centerX, y: send.centerY)
        } else if keyboardIsVisible(before) {
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

    private func keyboardSendButton(
        in snapshot: AccessibilitySnapshot
    ) -> AccessibilityNode? {
        snapshot.nodes
            .filter {
                $0.kind == "Button"
                    && ($0.label == "发送" || $0.label == "send")
                    && $0.x >= 280
                    && $0.y >= 650
            }
            .max(by: { $0.y < $1.y })
    }

    private func keyboardIsVisible(
        _ snapshot: AccessibilitySnapshot
    ) -> Bool {
        snapshot.source.contains("Keyboard,")
            || snapshot.source.contains("隐藏输入法")
            || snapshot.source.contains("数字键盘")
    }

    private enum KeyboardLanguage {
        case chinese
        case english
    }

    private func selectKeyboard(
        _ target: KeyboardLanguage,
        snapshot initial: AccessibilitySnapshot
    ) async throws {
        var snapshot = initial
        for _ in 0..<3 {
            if keyboardLanguage(in: snapshot) == target {
                return
            }
            try await bridge.tap(
                x: Self.languageKey.x,
                y: Self.languageKey.y
            )
            try await bridge.wait(seconds: 0.35)
            snapshot = try await bridge.snapshot(bundleID: Self.bundleID)
        }
        guard keyboardLanguage(in: snapshot) == target else {
            throw QianniuDriverError.keyboardLanguageNotVerified
        }
    }

    private func keyboardLanguage(
        in snapshot: AccessibilitySnapshot
    ) -> KeyboardLanguage? {
        if snapshot.source.contains("Key, label: 'space'"),
           snapshot.source.contains("Button, label: 'send'") {
            return .english
        }
        if snapshot.source.contains("Key, label: '空格'"),
           snapshot.source.contains("Button, label: '发送'") {
            return .chinese
        }
        if snapshot.source.contains("隐藏输入法"),
           snapshot.source.contains("数字键盘") {
            return .chinese
        }
        return nil
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
