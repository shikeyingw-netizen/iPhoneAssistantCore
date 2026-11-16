import Foundation
import XCTest
@testable import AssistantCore

final class AutomationControlTests: XCTestCase {
    func testNewDatabaseStartsFailClosed() throws {
        let store = try makeStore()

        XCTAssertEqual(try store.current().state, .humanTakeover)
    }

    func testTakeoverPersistsAcrossReopen() throws {
        let path = temporaryDatabaseURL()
        let first = try SQLiteAutomationControlStore(
            databaseURL: path
        )
        _ = try first.update(
            to: .automationPaused,
            actor: "user",
            reason: "pause"
        )
        _ = try first.update(
            to: .humanTakeover,
            actor: "user",
            reason: "manual control"
        )

        let reopened = try SQLiteAutomationControlStore(
            databaseURL: path
        )
        let record = try reopened.current()

        XCTAssertEqual(record.state, .humanTakeover)
        XCTAssertEqual(record.reason, "manual control")
        XCTAssertEqual(
            try reopened.auditTrail().map(\.state),
            [.automationPaused, .humanTakeover]
        )
    }

    func testResumeRequiresAwaitingManualResume() throws {
        let store = try makeStore()

        XCTAssertThrowsError(
            try store.update(
                to: .automatic,
                actor: "remote",
                reason: "bypass"
            )
        ) { error in
            XCTAssertEqual(
                error as? AutomationControlError,
                .invalidTransition(
                    from: .humanTakeover,
                    to: .automatic
                )
            )
        }

        _ = try store.update(
            to: .awaitingManualResume,
            actor: "user",
            reason: "preflight passed"
        )
        let resumed = try store.update(
            to: .automatic,
            actor: "user",
            reason: "explicit approval"
        )

        XCTAssertEqual(resumed.state, .automatic)
    }

    func testAnyBlockingStateCanTriggerHumanTakeoverAgain() {
        for source in AutomationControlState.allCases {
            XCTAssertTrue(
                SQLiteAutomationControlStore.canTransition(
                    from: source,
                    to: .humanTakeover
                )
            )
        }
    }

    private func makeStore() throws -> SQLiteAutomationControlStore {
        try SQLiteAutomationControlStore(
            databaseURL: temporaryDatabaseURL()
        )
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }
}
