import Foundation

public protocol AppUIBridge: Sendable {
    func launch(bundleID: String) async throws
    func snapshot(bundleID: String) async throws -> AccessibilitySnapshot
    func tap(x: Double, y: Double) async throws
    func type(text: String, x: Double, y: Double, clear: Bool) async throws
    func typeOnKeyboard(
        text: String,
        x: Double,
        y: Double
    ) async throws
    func pasteText(
        text: String,
        x: Double,
        y: Double
    ) async throws
    func wait(seconds: Double) async throws
    func now() -> Date
}

public extension AppUIBridge {
    func typeOnKeyboard(
        text: String,
        x: Double,
        y: Double
    ) async throws {
        try await type(text: text, x: x, y: y, clear: false)
    }

    func pasteText(
        text: String,
        x: Double,
        y: Double
    ) async throws {
        try await type(text: text, x: x, y: y, clear: false)
    }
}
