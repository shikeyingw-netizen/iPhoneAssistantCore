import Foundation

public typealias DeepSeekUIBridge = AppUIBridge

public struct DeepSeekDriverConfiguration: Sendable {
    public let bundleID: String
    public let inputTimeout: TimeInterval
    public let responseTimeout: TimeInterval
    public let pollInterval: TimeInterval
    public let stabilityInterval: TimeInterval

    public init(
        bundleID: String = StoreCatalog.deepSeekBundleIdentifier,
        inputTimeout: TimeInterval = 20,
        responseTimeout: TimeInterval = 45,
        pollInterval: TimeInterval = 0.25,
        stabilityInterval: TimeInterval = 0.5
    ) {
        self.bundleID = bundleID
        self.inputTimeout = inputTimeout
        self.responseTimeout = responseTimeout
        self.pollInterval = pollInterval
        self.stabilityInterval = stabilityInterval
    }
}

public struct DeepSeekTurnResult: Equatable, Sendable {
    public let success: Bool
    public let answer: String
    public let latency: TimeInterval
    public let rateLimited: Bool
    public let loginRequired: Bool
    public let failureReason: String?
    public let previousAnswerRetained: Bool

    public init(
        success: Bool,
        answer: String,
        latency: TimeInterval,
        rateLimited: Bool,
        loginRequired: Bool,
        failureReason: String?,
        previousAnswerRetained: Bool
    ) {
        self.success = success
        self.answer = answer
        self.latency = latency
        self.rateLimited = rateLimited
        self.loginRequired = loginRequired
        self.failureReason = failureReason
        self.previousAnswerRetained = previousAnswerRetained
    }
}

public actor DeepSeekAppDriver {
    private let bridge: DeepSeekUIBridge
    private let configuration: DeepSeekDriverConfiguration

    public init(
        bridge: DeepSeekUIBridge,
        configuration: DeepSeekDriverConfiguration = DeepSeekDriverConfiguration()
    ) {
        self.bridge = bridge
        self.configuration = configuration
    }

    public func runTurn(
        prompt: String,
        expectedToken: String,
        previousExpectedToken: String? = nil
    ) async throws -> DeepSeekTurnResult {
        let started = bridge.now()
        try await bridge.launch(bundleID: configuration.bundleID)

        guard let input = try await waitForInput() else {
            return DeepSeekTurnResult(
                success: false,
                answer: "",
                latency: bridge.now().timeIntervalSince(started),
                rateLimited: false,
                loginRequired: false,
                failureReason: "DeepSeek input not found",
                previousAnswerRetained: false
            )
        }
        try await bridge.type(
            text: prompt,
            x: input.centerX,
            y: input.centerY,
            clear: true
        )
        var snapshot = try await bridge.snapshot(bundleID: configuration.bundleID)
        guard snapshot.nodes(kind: "TextView").contains(where: {
            normalizedInput($0.value) == normalizedInput(prompt)
        }) else {
            return DeepSeekTurnResult(
                success: false,
                answer: "",
                latency: bridge.now().timeIntervalSince(started),
                rateLimited: false,
                loginRequired: false,
                failureReason: "typed prompt not verified",
                previousAnswerRetained: false
            )
        }
        guard let send = snapshot.firstNode(label: "发送") else {
            return DeepSeekTurnResult(
                success: false,
                answer: "",
                latency: bridge.now().timeIntervalSince(started),
                rateLimited: false,
                loginRequired: false,
                failureReason: "send button not found",
                previousAnswerRetained: false
            )
        }
        try await bridge.tap(x: send.centerX, y: send.centerY)

        let responseStarted = bridge.now()
        let deadline = responseStarted.addingTimeInterval(configuration.responseTimeout)
        while bridge.now() < deadline {
            try await bridge.wait(seconds: configuration.pollInterval)
            snapshot = try await bridge.snapshot(bundleID: configuration.bundleID)
            if loginRequired(snapshot.source) {
                return DeepSeekTurnResult(
                    success: false,
                    answer: "",
                    latency: bridge.now().timeIntervalSince(started),
                    rateLimited: rateLimited(snapshot.source),
                    loginRequired: true,
                    failureReason: "DeepSeek requires login or verification",
                    previousAnswerRetained: retained(previousExpectedToken, in: snapshot.source)
                )
            }
            if let answer = answer(in: snapshot, expectedToken: expectedToken) {
                try await bridge.wait(seconds: configuration.stabilityInterval)
                let stable = try await bridge.snapshot(bundleID: configuration.bundleID)
                if self.answer(in: stable, expectedToken: expectedToken) != nil {
                    return DeepSeekTurnResult(
                        success: true,
                        answer: answer,
                        latency: bridge.now().timeIntervalSince(started),
                        rateLimited: false,
                        loginRequired: false,
                        failureReason: nil,
                        previousAnswerRetained: retained(
                            previousExpectedToken,
                            in: stable.source
                        )
                    )
                }
            }
        }
        return DeepSeekTurnResult(
            success: false,
            answer: "",
            latency: bridge.now().timeIntervalSince(started),
            rateLimited: rateLimited(snapshot.source),
            loginRequired: false,
            failureReason: "DeepSeek response timeout",
            previousAnswerRetained: retained(previousExpectedToken, in: snapshot.source)
        )
    }

    public func runCustomerTurn(
        prompt: String,
        turnToken: String,
        previousExpectedToken: String? = nil
    ) async throws -> DeepSeekTurnResult {
        let token = turnToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard token.count >= 8, prompt.contains(token) else {
            return DeepSeekTurnResult(
                success: false,
                answer: "",
                latency: 0,
                rateLimited: false,
                loginRequired: false,
                failureReason: "customer turn token is missing from the prompt",
                previousAnswerRetained: false
            )
        }
        let raw = try await runTurn(
            prompt: prompt,
            expectedToken: token,
            previousExpectedToken: previousExpectedToken
        )
        guard raw.success else {
            return raw
        }
        let answer = raw.answer
            .replacingOccurrences(of: token, with: "")
            .trimmingCharacters(
                in: .whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: "：:【】[]-")
                )
            )
        guard
            answer.count >= 2,
            !answer.contains(token),
            !answer.contains("客服作答校验"),
            !answer.contains("内部校验")
        else {
            return DeepSeekTurnResult(
                success: false,
                answer: "",
                latency: raw.latency,
                rateLimited: raw.rateLimited,
                loginRequired: raw.loginRequired,
                failureReason: (
                    "DeepSeek answer did not contain this turn's verified "
                    + "token with a customer-visible body"
                ),
                previousAnswerRetained: raw.previousAnswerRetained
            )
        }
        return DeepSeekTurnResult(
            success: true,
            answer: answer,
            latency: raw.latency,
            rateLimited: false,
            loginRequired: false,
            failureReason: nil,
            previousAnswerRetained: raw.previousAnswerRetained
        )
    }

    private func waitForInput() async throws -> AccessibilityNode? {
        let deadline = bridge.now().addingTimeInterval(configuration.inputTimeout)
        while bridge.now() < deadline {
            let snapshot = try await bridge.snapshot(bundleID: configuration.bundleID)
            if let input = promptInput(in: snapshot.nodes) {
                return input
            }
            try await bridge.wait(seconds: configuration.pollInterval)
        }
        return nil
    }

    private func promptInput(in nodes: [AccessibilityNode]) -> AccessibilityNode? {
        nodes
            .filter {
                $0.kind == "TextView"
                    && (300...370).contains($0.width)
                    && $0.y >= 300
            }
            .max(by: { $0.y < $1.y })
    }

    private func answer(
        in snapshot: AccessibilitySnapshot,
        expectedToken: String
    ) -> String? {
        snapshot.nodes.first {
            $0.label.contains(expectedToken) && $0.x < 120 && $0.y > 100
        }?.label
    }

    private func rateLimited(_ source: String) -> Bool {
        MerchantPolicy.containsAny(
            source,
            ["请求过于频繁", "操作过于频繁", "稍后再试", "达到上限", "使用次数"]
        )
    }

    private func loginRequired(_ source: String) -> Bool {
        MerchantPolicy.containsAny(
            source,
            ["登录后继续", "请登录", "验证码", "安全验证", "账号验证"]
        )
    }

    private func normalizedInput(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private func retained(_ previous: String?, in source: String) -> Bool {
        guard let previous, !previous.isEmpty else {
            return false
        }
        return source.contains(previous)
    }

}
