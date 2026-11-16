import Foundation
import XCTest
@testable import AssistantCore

final class DeepSeekAppDriverTests: XCTestCase {
    func testAccessibilityTreeParsesInputAndAnswer() {
        let snapshot = AccessibilityTreeParser.parse(
            """
            Application, label: 'DeepSeek', {{0, 0}, {390, 844}}
              TextView, value: '测试输入', {{22, 704}, {346, 46}}
              Button, label: '发送', {{330, 418}, {36, 36}}
              Other, label: '客服测试成功', {{24, 214}, {342, 28}}
            """
        )
        XCTAssertEqual(snapshot.nodes(kind: "TextView").first?.value, "测试输入")
        XCTAssertEqual(snapshot.firstNode(label: "发送")?.centerX, 348)
        XCTAssertEqual(snapshot.firstNode(label: "客服测试成功")?.y, 214)
    }

    func testTenConsecutiveAppTurns() async throws {
        let bridge = FakeDeepSeekBridge()
        let driver = DeepSeekAppDriver(
            bridge: bridge,
            configuration: DeepSeekDriverConfiguration(
                responseTimeout: 3,
                pollInterval: 0.1,
                stabilityInterval: 0.1
            )
        )
        var previous: String?

        for index in 1...10 {
            let token = String(format: "客服测试成功%02d", index)
            let result = try await driver.runTurn(
                prompt: "请只回复：\(token)",
                expectedToken: token,
                previousExpectedToken: previous
            )
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.answer, token)
            XCTAssertFalse(result.rateLimited)
            XCTAssertFalse(result.loginRequired)
            if let previous {
                XCTAssertTrue(result.previousAnswerRetained)
                XCTAssertTrue(bridge.sourceContains(previous))
            }
            previous = token
        }
    }

    func testRateLimitIsReported() async throws {
        let bridge = FakeDeepSeekBridge(mode: .rateLimited)
        let driver = DeepSeekAppDriver(
            bridge: bridge,
            configuration: DeepSeekDriverConfiguration(
                responseTimeout: 1,
                pollInterval: 0.1,
                stabilityInterval: 0.1
            )
        )
        let result = try await driver.runTurn(
            prompt: "请只回复：客服测试成功99",
            expectedToken: "客服测试成功99"
        )
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.rateLimited)
        XCTAssertEqual(result.failureReason, "DeepSeek response timeout")
    }

    func testCustomerTurnRequiresAndStripsCurrentTurnToken() async throws {
        let bridge = FakeDeepSeekBridge()
        let driver = DeepSeekAppDriver(
            bridge: bridge,
            configuration: DeepSeekDriverConfiguration(
                responseTimeout: 3,
                pollInterval: 0.1,
                stabilityInterval: 0.1
            )
        )

        let token = "WB1234567890AB"
        let result = try await driver.runCustomerTurn(
            prompt: """
            客服作答校验
            \(token)
            请回复客服测试成功
            """,
            turnToken: token
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.answer, "客服测试成功")
        XCTAssertNil(result.failureReason)
    }
}

private final class FakeDeepSeekBridge: DeepSeekUIBridge, @unchecked Sendable {
    enum Mode {
        case success
        case rateLimited
    }

    private enum Phase {
        case idle
        case typed
        case sent
    }

    private let lock = NSLock()
    private let mode: Mode
    private var phase: Phase = .idle
    private var typedPrompt = ""
    private var expectedToken = ""
    private var verifiedCustomerPrompt = false
    private var history: [String] = []
    private var currentDate = Date(timeIntervalSince1970: 1_800_000_000)

    init(mode: Mode = .success) {
        self.mode = mode
    }

    func launch(bundleID: String) async throws {
        lock.withLock {
            phase = .idle
        }
    }

    func snapshot(bundleID: String) async throws -> AccessibilitySnapshot {
        lock.withLock {
            AccessibilityTreeParser.parse(sourceLocked(), capturedAt: currentDate)
        }
    }

    func tap(x: Double, y: Double) async throws {
        lock.withLock {
            phase = .sent
        }
    }

    func type(text: String, x: Double, y: Double, clear: Bool) async throws {
        lock.withLock {
            typedPrompt = text
            if
                let match = text.range(
                    of: #"WB[A-F0-9]{12}"#,
                    options: .regularExpression
                )
            {
                expectedToken = String(text[match])
            } else {
                expectedToken = text.replacingOccurrences(
                    of: "请只回复：",
                    with: ""
                )
            }
            verifiedCustomerPrompt = text.contains("客服作答校验")
            phase = .typed
        }
    }

    func wait(seconds: Double) async throws {
        lock.withLock {
            currentDate = currentDate.addingTimeInterval(seconds)
        }
    }

    func now() -> Date {
        lock.withLock {
            currentDate
        }
    }

    func sourceContains(_ text: String) -> Bool {
        lock.withLock {
            sourceLocked().contains(text)
        }
    }

    private func sourceLocked() -> String {
        switch phase {
        case .idle:
            return """
            Application, label: 'DeepSeek', {{0, 0}, {390, 844}}
              TextView, {{22, 704}, {346, 46}}
              Button, label: '发送', {{330, 418}, {36, 36}}
            \(historyLines())
            """
        case .typed:
            let escapedPrompt = typedPrompt
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
            return """
            Application, label: 'DeepSeek', {{0, 0}, {390, 844}}
              TextView, value: '\(escapedPrompt)', {{22, 704}, {346, 46}}
              Button, label: '发送', {{330, 418}, {36, 36}}
            \(historyLines())
            """
        case .sent:
            if mode == .rateLimited {
                return """
                Application, label: 'DeepSeek', {{0, 0}, {390, 844}}
                  TextView, {{22, 704}, {346, 46}}
                  Other, label: '请求过于频繁，请稍后再试', {{24, 214}, {342, 28}}
                \(historyLines())
                """
            }
            if !history.contains(expectedToken) {
                history.append(expectedToken)
            }
            let answerLabel = verifiedCustomerPrompt
                ? "\(expectedToken) 客服测试成功"
                : expectedToken
            return """
            Application, label: 'DeepSeek', {{0, 0}, {390, 844}}
              TextView, {{22, 704}, {346, 46}}
              Other, label: '\(answerLabel)', {{24, 214}, {342, 28}}
            \(historyLines())
            """
        }
    }

    private func historyLines() -> String {
        history.enumerated().map { index, token in
            "  Other, label: '\(token)', {{24, \(300 + index * 50)}, {342, 28}}"
        }.joined(separator: "\n")
    }
}
