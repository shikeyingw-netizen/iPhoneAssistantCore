import Foundation
import XCTest
@testable import AssistantCore

final class QianniuDriverTests: XCTestCase {
    func testDirectChatRequiresBackButtonAndInput() {
        let direct = QianniuPageParser.parse(
            AccessibilityTreeParser.parse(source())
        )
        let home = QianniuPageParser.parse(
            AccessibilityTreeParser.parse(
                "Application, label: '千牛', {{0, 0}, {390, 844}}"
            )
        )

        XCTAssertEqual(direct, .directChat(customer: "客户乙"))
        XCTAssertEqual(home, .unknown)
    }

    func testTypedReplyAndVerifiedSend() async throws {
        let bridge = FakeQianniuBridge()
        let driver = QianniuDriver(bridge: bridge)
        let reply = "亲，A/B型配料基本一样，主要是比例不同。"

        try await driver.prepareReply(reply)
        let receipt = try await driver.sendPreparedReply(reply)

        XCTAssertEqual(receipt, .sentVerified)
        XCTAssertEqual(bridge.currentState(), .sent)
        XCTAssertEqual(bridge.tapCount(), 1)
    }

    func testDirectChatFindsComposerShiftedUpByKeyboard() {
        let source = """
        Application, label: '千牛', {{0, 0}, {390, 844}}
          Button, label: 'back', {{12, 57}, {24, 24}}
          Button, label: '客户乙', {{55, 59}, {64, 21}}
          TextView, {{78, 429}, {168, 37}}
          Button, {{246, 429}, {37, 37}}
          Other, label: '隐藏输入法', {{336, 502}, {54, 42}}
          Other, label: '数字键盘', {{67, 716}, {81, 50}}
        """

        let snapshot = AccessibilityTreeParser.parse(source)
        let input = QianniuPageParser.input(in: snapshot)

        XCTAssertEqual(
            QianniuPageParser.parse(snapshot),
            .directChat(customer: "客户乙")
        )
        XCTAssertEqual(input?.centerY, 447.5)
    }

    func testSendWithoutVerificationBecomesUncertain() async throws {
        let bridge = FakeQianniuBridge(verifySend: false)
        let driver = QianniuDriver(bridge: bridge)
        let reply = "亲，收到您的消息，我这边马上为您看一下。"
        try await driver.prepareReply(reply)

        let receipt = try await driver.sendPreparedReply(reply)

        guard case let .sendUncertain(reason) = receipt else {
            return XCTFail("unverified send must be uncertain")
        }
        XCTAssertTrue(reason.contains("not uniquely verified"))
        XCTAssertEqual(bridge.tapCount(), 1)
    }

    func testTypingFailureStopsBeforeSend() async throws {
        let bridge = FakeQianniuBridge(dropTypedText: true)
        let driver = QianniuDriver(bridge: bridge)

        do {
            try await driver.prepareReply("测试回复")
            XCTFail("unverified typing must stop the flow")
        } catch {
            XCTAssertEqual(
                error as? QianniuDriverError,
                .typedReplyNotVerified
            )
        }
        XCTAssertEqual(bridge.tapCount(), 0)
    }

    private func source() -> String {
        """
        Application, label: '千牛', {{0, 0}, {390, 844}}
          Button, label: 'back', {{12, 57}, {24, 24}}
          Button, label: '客户乙', {{55, 59}, {64, 21}}
          Button, label: 'https://example.invalid/avatar.png', {{310, 58}, {24, 24}}
          Button, label: 'mine_circle', {{350, 58}, {24, 24}}
          TextView, {{78, 763}, {168, 37}}
          Button, {{246, 763}, {37, 37}}
          Button, {{293, 763}, {37, 37}}
          Button, {{340, 763}, {37, 37}}
        """
    }
}

private final class FakeQianniuBridge: AppUIBridge, @unchecked Sendable {
    enum State {
        case direct
        case typed
        case sent
        case uncertain
    }

    private let lock = NSLock()
    private let verifySend: Bool
    private let dropTypedText: Bool
    private var typedReply = ""
    private var state: State = .direct
    private var taps = 0
    private var keyboardVisible = false
    private var keyboardEnglish = false
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    init(verifySend: Bool = true, dropTypedText: Bool = false) {
        self.verifySend = verifySend
        self.dropTypedText = dropTypedText
    }

    func currentState() -> State {
        lock.withLock { state }
    }

    func tapCount() -> Int {
        lock.withLock { taps }
    }

    func launch(bundleID: String) async throws {}

    func snapshot(bundleID: String) async throws -> AccessibilitySnapshot {
        lock.withLock {
            AccessibilityTreeParser.parse(sourceLocked(), capturedAt: clock)
        }
    }

    func tap(x: Double, y: Double) async throws {
        lock.withLock {
            if y >= 700 && x >= 300 {
                taps += 1
                state = verifySend ? .sent : .uncertain
                keyboardVisible = false
                return
            }
            if keyboardVisible,
               x <= 80,
               y >= 770 {
                keyboardEnglish.toggle()
                return
            }
            if x <= 260,
               y >= 400 {
                keyboardVisible = true
            }
        }
    }

    func type(
        text: String,
        x: Double,
        y: Double,
        clear: Bool
    ) async throws {
        lock.withLock {
            typedReply =
                dropTypedText || !keyboardVisible || !keyboardEnglish
                ? ""
                : text
            state = .typed
            keyboardVisible = false
        }
    }

    func wait(seconds: Double) async throws {}

    func now() -> Date {
        clock
    }

    private func sourceLocked() -> String {
        let input = (state == .typed || state == .uncertain)
            ? " value: '\(typedReply)',"
            : ""
        let keyboard: String
        if !keyboardVisible {
            keyboard = ""
        } else if keyboardEnglish {
            keyboard = """
              Keyboard, {{0, 553}, {390, 233}}
                Key, label: 'space', id: 'space', {{97, 722}, {195, 46}}
                Button, label: 'send', id: 'Send', {{292, 722}, {97, 46}}
              Button, label: '下一个键盘', value: '简体拼音', {{8, 775}, {68, 68}}
            """
        } else {
            keyboard = """
              Other, label: '隐藏输入法', {{336, 502}, {54, 42}}
              Other, label: '数字键盘', {{67, 716}, {81, 50}}
              Button, label: '下一个键盘', value: 'English (US)', {{8, 775}, {68, 68}}
            """
        }
        let sentMessage = state == .sent
            ? "  Other, label: '\(typedReply)', {{338, 646}, {40, 30}}\n"
            : ""
        return """
        Application, label: '千牛', {{0, 0}, {390, 844}}
          Button, label: 'back', {{12, 57}, {24, 24}}
          Button, label: '客户乙', {{55, 59}, {64, 21}}
          Button, label: 'mine_circle', {{350, 58}, {24, 24}}
          TextView,\(input) {{78, 763}, {168, 37}}
          Button, {{246, 763}, {37, 37}}
          Button, {{293, 763}, {37, 37}}
          Button, {{340, 763}, {37, 37}}
        \(sentMessage)
        \(keyboard)
        """
    }
}
