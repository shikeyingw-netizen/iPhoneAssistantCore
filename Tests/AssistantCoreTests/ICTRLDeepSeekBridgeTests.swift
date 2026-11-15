import Foundation
import XCTest
@testable import AssistantCore

final class ICTRLDeepSeekBridgeTests: XCTestCase {
    func testBridgeDrivesExistingDeepSeekTurnContract() async throws {
        let rpc = FakeICTRLRPC()
        let bridge = ICTRLDeepSeekBridge(
            rpc: rpc,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let driver = DeepSeekAppDriver(
            bridge: bridge,
            configuration: DeepSeekDriverConfiguration(
                responseTimeout: 3,
                pollInterval: 0.001,
                stabilityInterval: 0.001
            )
        )
        let expected = "客服测试成功"

        let result = try await driver.runTurn(
            prompt: "请只回复：\(expected)",
            expectedToken: expected
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.answer, expected)
        let calls = await rpc.methods()
        XCTAssertEqual(calls.first, "launch_app")
        XCTAssertTrue(calls.contains("page_source"))
        XCTAssertTrue(calls.contains("type"))
        XCTAssertTrue(calls.contains("tap"))
    }

    func testBridgeRejectsWrongForegroundBundle() async throws {
        let rpc = FakeICTRLRPC(actualBundleID: "com.example.other")
        let bridge = ICTRLDeepSeekBridge(rpc: rpc)

        do {
            _ = try await bridge.snapshot(
                bundleID: StoreCatalog.deepSeekBundleIdentifier
            )
            XCTFail("wrong app must be rejected")
        } catch {
            XCTAssertEqual(
                error as? ICTRLDeepSeekBridgeError,
                .wrongForegroundApp(
                    expected: StoreCatalog.deepSeekBundleIdentifier,
                    actual: "com.example.other"
                )
            )
        }
    }

    func testBridgeRequiresSnapshotBeforeTap() async throws {
        let bridge = ICTRLDeepSeekBridge(rpc: FakeICTRLRPC())

        do {
            try await bridge.tap(x: 10, y: 20)
            XCTFail("tap before snapshot must fail")
        } catch {
            XCTAssertEqual(
                error as? ICTRLDeepSeekBridgeError,
                .noObservedForegroundApp
            )
        }
    }
}

private actor FakeICTRLRPC: ICTRLRPCInvoking {
    enum Phase {
        case idle
        case typed
        case sent
    }

    private let actualBundleID: String
    private var phase: Phase = .idle
    private var typedText = ""
    private var calls: [String] = []

    init(actualBundleID: String = StoreCatalog.deepSeekBundleIdentifier) {
        self.actualBundleID = actualBundleID
    }

    func methods() -> [String] {
        calls
    }

    func call(
        method: String,
        params: ICTRLJSONValue
    ) async throws -> ICTRLJSONValue {
        calls.append(method)
        switch method {
        case "launch_app":
            phase = .idle
            return .object([:])
        case "page_source":
            return .object([
                "bundle_id": .string(actualBundleID),
                "source": .string(source()),
            ])
        case "type":
            typedText = params["text"]?.stringValue ?? ""
            phase = .typed
            return .object([:])
        case "tap":
            phase = .sent
            return .object([:])
        default:
            return .object([:])
        }
    }

    private func source() -> String {
        let inputValue: String
        switch phase {
        case .idle:
            inputValue = ""
        case .typed, .sent:
            inputValue = " value: '\(typedText)'"
        }
        let answer = phase == .sent
            ? "  Other, label: '客服测试成功', {{24, 214}, {342, 28}}\n"
            : ""
        return """
        Application, label: 'DeepSeek', {{0, 0}, {390, 844}}
          TextView,\(inputValue) {{22, 704}, {346, 46}}
          Button, label: '发送', {{330, 418}, {36, 36}}
        \(answer)
        """
    }
}
