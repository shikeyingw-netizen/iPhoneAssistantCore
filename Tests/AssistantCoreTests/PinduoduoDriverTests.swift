import Foundation
import XCTest
@testable import AssistantCore

final class PinduoduoDriverTests: XCTestCase {
    func testPendingRowParserFindsCountdownAndIgnoresRepliedSection() {
        let snapshot = AccessibilityTreeParser.parse(pendingListSource())

        let rows = PinduoduoPageParser.pendingRows(snapshot)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].section, "其他店铺消息(1)")
        XCTAssertEqual(rows[0].storeName, "央科商贸")
        XCTAssertEqual(rows[0].marker, "160秒后超时")
        XCTAssertTrue(rows[0].identity.contains("央科商贸"))
    }

    func testOtherStoreSectionWithoutCountdownIsStillDetected() {
        let source = pendingListSource().replacingOccurrences(
            of: "160秒后超时",
            with: "等待平台同步"
        )

        let rows = PinduoduoPageParser.pendingRows(
            AccessibilityTreeParser.parse(source)
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].marker, "other-store-section")
    }

    func testDriverOpensOnlyTheCurrentlyObservedPendingRow() async throws {
        let bridge = FakeCommerceBridge(state: .pending)
        let driver = PinduoduoDriver(bridge: bridge)
        let rows = PinduoduoPageParser.pendingRows(
            AccessibilityTreeParser.parse(pendingListSource())
        )
        let row = try XCTUnwrap(rows.first)

        let customer = try await driver.open(row)

        XCTAssertEqual(customer, "客户甲")
        let state = bridge.currentState()
        XCTAssertEqual(state, .direct)
    }

    func testDriverRejectsStalePendingRowWithoutTapping() async throws {
        let bridge = FakeCommerceBridge(state: .pending)
        let driver = PinduoduoDriver(bridge: bridge)
        let stale = PinduoduoPendingRow(
            section: "其他店铺消息(1)",
            storeName: "旧任务",
            preview: "旧预览",
            marker: "160秒后超时",
            identity: "stale-identity",
            centerX: 10,
            centerY: 10
        )

        do {
            _ = try await driver.open(stale)
            XCTFail("stale pending row must be rejected")
        } catch {
            XCTAssertEqual(
                error as? PinduoduoDriverError,
                .stalePendingRow
            )
        }
        let tapCount = bridge.tapCount()
        XCTAssertEqual(tapCount, 0)
    }

    func testReplyIsSentOnlyAfterTypedValueVerification() async throws {
        let bridge = FakeCommerceBridge(state: .direct)
        let driver = PinduoduoDriver(bridge: bridge)
        let reply = "亲，当天16:30前付款当天发货哦。"

        try await driver.prepareReply(reply)
        let receipt = try await driver.sendPreparedReply(reply)

        XCTAssertEqual(receipt, .sentVerified)
        let state = bridge.currentState()
        let tapCount = bridge.tapCount()
        XCTAssertEqual(state, .sent)
        XCTAssertEqual(tapCount, 1)
    }

    func testUnverifiedSendReturnsUncertainAndIsNotRetried() async throws {
        let bridge = FakeCommerceBridge(state: .direct, verifySend: false)
        let driver = PinduoduoDriver(bridge: bridge)
        let reply = "亲，收到您的消息，我这边马上为您看一下。"
        try await driver.prepareReply(reply)

        let receipt = try await driver.sendPreparedReply(reply)

        guard case let .sendUncertain(reason) = receipt else {
            return XCTFail("unverified send must be uncertain")
        }
        XCTAssertTrue(reason.contains("not uniquely verified"))
        let tapCount = bridge.tapCount()
        XCTAssertEqual(tapCount, 1)
    }

    func testSendButtonIsFoundBesideShiftedComposerWhenKeyboardIsUp()
        async throws {
        let bridge = FakeCommerceBridge(
            state: .direct,
            keyboardShifted: true
        )
        let driver = PinduoduoDriver(bridge: bridge)
        let reply = "客服测试成功"

        try await driver.prepareReply(reply)
        let receipt = try await driver.sendPreparedReply(reply)

        XCTAssertEqual(receipt, .sentVerified)
        XCTAssertEqual(bridge.currentState(), .sent)
        XCTAssertEqual(bridge.tapCount(), 1)
    }

    private func pendingListSource() -> String {
        """
        Application, label: '拼多多商家版', {{0, 0}, {390, 844}}
          NavigationBar, id: 'PMChatContainerView', {{0, 47}, {390, 44}}
          Other, label: '其他店铺消息(1)', {{15, 375}, {360, 30}}
          StaticText, label: '央科商贸', {{75, 416}, {68, 20}}
          StaticText, label: '亲，喜欢的话，您可点击发起拼单完成支付', {{74, 442}, {217, 16}}
          StaticText, label: '160秒后超时', {{298, 440}, {79, 20}}
          Other, label: '已回复(2)', {{15, 479}, {360, 30}}
          StaticText, label: '其他客户', {{75, 520}, {68, 20}}
        """
    }
}

private final class FakeCommerceBridge: AppUIBridge, @unchecked Sendable {
    enum State: Equatable {
        case pending
        case direct
        case typed
        case sent
        case uncertain
    }

    private let lock = NSLock()
    private var state: State
    private let verifySend: Bool
    private var taps = 0
    private var typedReply = ""
    private let keyboardShifted: Bool
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    init(
        state: State,
        verifySend: Bool = true,
        keyboardShifted: Bool = false
    ) {
        self.state = state
        self.verifySend = verifySend
        self.keyboardShifted = keyboardShifted
    }

    func currentState() -> State {
        lock.withLock { state }
    }

    func tapCount() -> Int {
        lock.withLock { taps }
    }

    func launch(bundleID: String) async throws {
        if state == .sent || state == .uncertain {
            state = .direct
        }
    }

    func snapshot(bundleID: String) async throws -> AccessibilitySnapshot {
        lock.withLock {
            AccessibilityTreeParser.parse(sourceLocked(), capturedAt: clock)
        }
    }

    func tap(x: Double, y: Double) async throws {
        lock.withLock {
            taps += 1
            if state == .pending {
                state = .direct
            } else if (state == .typed || state == .direct)
                && (
                    y >= 730
                        || (keyboardShifted && y >= 430 && y <= 470)
                ) {
                state = verifySend ? .sent : .uncertain
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
            typedReply = text
            state = .typed
        }
    }

    func wait(seconds: Double) async throws {}

    func now() -> Date {
        clock
    }

    private func sourceLocked() -> String {
        if state == .pending {
            return """
            Application, label: '拼多多商家版', {{0, 0}, {390, 844}}
              NavigationBar, id: 'PMChatContainerView', {{0, 47}, {390, 44}}
              Other, label: '其他店铺消息(1)', {{15, 375}, {360, 30}}
              StaticText, label: '央科商贸', {{75, 416}, {68, 20}}
              StaticText, label: '亲，喜欢的话，您可点击发起拼单完成支付', {{74, 442}, {217, 16}}
              StaticText, label: '160秒后超时', {{298, 440}, {79, 20}}
              Other, label: '已回复(2)', {{15, 479}, {360, 30}}
            """
        }
        let input = (state == .typed || state == .uncertain)
            ? " value: '\(typedReply)',"
            : ""
        let sentMessage: String
        if state == .sent {
            sentMessage = """
              Other, label: '\(typedReply)', {{338, 650}, {40, 30}}
            """
        } else {
            sentMessage = ""
        }
        if keyboardShifted {
            return """
            Application, label: '拼多多商家版', {{0, 0}, {390, 844}}
              NavigationBar, id: '客户甲', {{0, 47}, {390, 44}}
                Button, {{294, 47}, {44, 44}}
                  StaticText, label: '订单', {{306, 73}, {20, 14}}
              TextView,\(input) {{57, 439}, {235, 27}}
              Button, {{308, 438}, {28, 28}}
              Button, {{349, 438}, {28, 28}}
            \(sentMessage)
            """
        }
        return """
        Application, label: '拼多多商家版', {{0, 0}, {390, 844}}
          NavigationBar, id: '客户甲', {{0, 47}, {390, 44}}
            Button, {{294, 47}, {44, 44}}
              StaticText, label: '订单', {{306, 73}, {20, 14}}
          TextView,\(input) {{57, 704}, {235, 36}}
          Button, {{349, 756}, {28, 32}}
        \(sentMessage)
        """
    }
}
