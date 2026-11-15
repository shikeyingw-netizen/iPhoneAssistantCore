import XCTest
@testable import AssistantCore

final class TaskStateMachineTests: XCTestCase {
    func testNormalSendFlow() throws {
        var machine = TaskStateMachine()
        try machine.apply(.claim)
        try machine.apply(.startProcessing)
        try machine.apply(.generateReply)
        try machine.apply(.requestSend)
        try machine.apply(.sendVerified)
        XCTAssertEqual(machine.state, .sentVerified)
        XCTAssertTrue(machine.isTerminalSuccess)
    }

    func testUncertainSendCannotBeRetriedBlindly() throws {
        var machine = TaskStateMachine(state: .sendPending)
        try machine.apply(.sendNotVerified)
        XCTAssertEqual(machine.state, .sendUncertain)
        XCTAssertTrue(machine.requiresHumanReconciliation)
        XCTAssertThrowsError(try machine.apply(.requestSend)) { error in
            XCTAssertEqual(
                error as? TaskTransitionError,
                TaskTransitionError.uncertainSendCannotBeRetried
            )
        }
    }

    func testUncertainSendCanBeVerifiedOrEscalated() throws {
        var verified = TaskStateMachine(state: .sendUncertain)
        try verified.apply(.sendVerified)
        XCTAssertEqual(verified.state, .sentVerified)

        var escalated = TaskStateMachine(state: .sendUncertain)
        try escalated.apply(.escalateToHuman)
        XCTAssertEqual(escalated.state, .manualReview)
    }
}
