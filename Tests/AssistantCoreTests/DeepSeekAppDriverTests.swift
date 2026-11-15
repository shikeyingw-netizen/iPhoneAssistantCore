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
    private var history: [String] = []
    private var currentDate = Date(timeIntervalSince1970: 1_800_000_000)

    init(mode: Mode = .success) {
        self.mode = mode
    }

    func launch(bundleID: String) async throws {
        lock.lock()
        phase = .idle
        lock.unlock()
    }

    func snapshot(bundleID: String) async throws -> AccessibilitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AccessibilityTreeParser.parse(sourceLocked(), capturedAt: currentDate)
    }

    func tap(x: Double, y: Double) async throws {
        lock.lock()
        phase = .sent
        lock.unlock()
    }

    func type(text: String, x: Double, y: Double, clear: Bool) async throws {
        lock.lock()
        typedPrompt = text
        expectedToken = text.replacingOccurrences(of: "请只回复：", with: "")
        phase = .typed
        lock.unlock()
    }

    func wait(seconds: Double) async throws {
        lock.lock()
        currentDate = currentDate.addingTimeInterval(seconds)
        lock.unlock()
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentDate
    }

    func sourceContains(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sourceLocked().contains(text)
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
            return """
            Application, label: 'DeepSeek', {{0, 0}, {390, 844}}
              TextView, value: '\(typedPrompt)', {{22, 704}, {346, 46}}
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
            return """
            Application, label: 'DeepSeek', {{0, 0}, {390, 844}}
              TextView, {{22, 704}, {346, 46}}
              Other, label: '\(expectedToken)', {{24, 214}, {342, 28}}
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
