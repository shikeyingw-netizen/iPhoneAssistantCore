import Foundation

public protocol AppUIBridge: Sendable {
    func launch(bundleID: String) async throws
    func snapshot(bundleID: String) async throws -> AccessibilitySnapshot
    func tap(x: Double, y: Double) async throws
    func type(text: String, x: Double, y: Double, clear: Bool) async throws
    func wait(seconds: Double) async throws
    func now() -> Date
}
