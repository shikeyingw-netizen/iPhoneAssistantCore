import Foundation

public enum ICTRLDeepSeekBridgeError: Error, Equatable {
    case malformedPageSource
    case wrongForegroundApp(expected: String, actual: String)
    case noObservedForegroundApp
}

public final class ICTRLDeepSeekBridge: DeepSeekUIBridge, @unchecked Sendable {
    private let rpc: any ICTRLRPCInvoking
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var lastBundleID: String?

    public init(
        rpc: any ICTRLRPCInvoking,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rpc = rpc
        self.clock = clock
    }

    public func launch(bundleID: String) async throws {
        _ = try await rpc.call(
            method: "launch_app",
            params: .object(["bundle_id": .string(bundleID)])
        )
        lock.withLock {
            lastBundleID = nil
        }
    }

    public func snapshot(bundleID: String) async throws -> AccessibilitySnapshot {
        let result = try await rpc.call(
            method: "page_source",
            params: .object([
                "max_elements": .number(5_000),
                "max_children": .number(2_000),
            ])
        )
        guard let source = result["source"]?.stringValue,
              let actualBundleID = result["bundle_id"]?.stringValue
        else {
            throw ICTRLDeepSeekBridgeError.malformedPageSource
        }
        guard actualBundleID == bundleID else {
            throw ICTRLDeepSeekBridgeError.wrongForegroundApp(
                expected: bundleID,
                actual: actualBundleID
            )
        }
        lock.withLock {
            lastBundleID = actualBundleID
        }
        return AccessibilityTreeParser.parse(source, capturedAt: clock())
    }

    public func tap(x: Double, y: Double) async throws {
        try requireObservedForegroundApp()
        _ = try await rpc.call(
            method: "tap",
            params: .object([
                "x": .number(x),
                "y": .number(y),
                "settle": .bool(true),
                "settle_timeout": .number(2),
            ])
        )
    }

    public func type(
        text: String,
        x: Double,
        y: Double,
        clear: Bool
    ) async throws {
        try requireObservedForegroundApp()
        _ = try await rpc.call(
            method: "type",
            params: .object([
                "x": .number(x),
                "y": .number(y),
                "text": .string(text),
                "clear": .bool(clear),
            ])
        )
        lock.withLock {
            lastBundleID = nil
        }
    }

    public func wait(seconds: Double) async throws {
        guard seconds > 0 else {
            return
        }
        try await Task.sleep(
            nanoseconds: UInt64(seconds * 1_000_000_000)
        )
    }

    public func now() -> Date {
        clock()
    }

    private func requireObservedForegroundApp() throws {
        let observed = lock.withLock { lastBundleID }
        guard observed != nil else {
            throw ICTRLDeepSeekBridgeError.noObservedForegroundApp
        }
    }
}
