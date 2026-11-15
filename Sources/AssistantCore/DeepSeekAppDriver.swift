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
        guard snapshot.nodes(kind: "TextView").contains(where: { $0.value == prompt }) else {
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

    public func runCustomerTurn(prompt: String) async throws -> DeepSeekTurnResult {
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
        guard snapshot.nodes(kind: "TextView").contains(where: { $0.value == prompt }) else {
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
        let baseline = assistantLabels(in: snapshot)
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
                    previousAnswerRetained: baselinePresent(baseline, in: snapshot)
                )
            }
            guard let candidate = newAssistantText(
                in: snapshot,
                baseline: baseline
            ) else {
                continue
            }
            try await bridge.wait(seconds: configuration.stabilityInterval)
            let stable = try await bridge.snapshot(bundleID: configuration.bundleID)
            if newAssistantText(in: stable, baseline: baseline) == candidate {
                return DeepSeekTurnResult(
                    success: true,
                    answer: candidate,
                    latency: bridge.now().timeIntervalSince(started),
                    rateLimited: false,
                    loginRequired: false,
                    failureReason: nil,
                    previousAnswerRetained: baselinePresent(
                        baseline,
                        in: stable
                    )
                )
            }
        }
        return DeepSeekTurnResult(
            success: false,
            answer: "",
            latency: bridge.now().timeIntervalSince(started),
            rateLimited: rateLimited(snapshot.source),
            loginRequired: false,
            failureReason: "DeepSeek response timeout",
            previousAnswerRetained: baselinePresent(baseline, in: snapshot)
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

    private func retained(_ previous: String?, in source: String) -> Bool {
        guard let previous, !previous.isEmpty else {
            return false
        }
        return source.contains(previous)
    }

    private func assistantLabels(
        in snapshot: AccessibilitySnapshot
    ) -> [String] {
        let ignored = Set([
            "复制",
            "喜欢",
            "不喜欢",
            "朗读",
            "分享",
            "重新生成",
        ])
        var seen = Set<String>()
        return snapshot.nodes
            .filter {
                ($0.kind == "Other" || $0.kind == "StaticText")
                    && $0.x >= 20
                    && $0.x < 120
                    && $0.y > 100
                    && $0.y < 680
                    && $0.width >= 20
                    && !$0.label.isEmpty
                    && !ignored.contains($0.label)
            }
            .sorted { $0.y < $1.y }
            .compactMap { node in
                seen.insert(node.label).inserted ? node.label : nil
            }
    }

    private func newAssistantText(
        in snapshot: AccessibilitySnapshot,
        baseline: [String]
    ) -> String? {
        let existing = Set(baseline)
        let labels = assistantLabels(in: snapshot).filter {
            !existing.contains($0)
        }
        guard !labels.isEmpty else {
            return nil
        }
        return labels.joined(separator: "\n")
    }

    private func baselinePresent(
        _ baseline: [String],
        in snapshot: AccessibilitySnapshot
    ) -> Bool {
        guard !baseline.isEmpty else {
            return false
        }
        let current = Set(assistantLabels(in: snapshot))
        return baseline.allSatisfy(current.contains)
    }
}
