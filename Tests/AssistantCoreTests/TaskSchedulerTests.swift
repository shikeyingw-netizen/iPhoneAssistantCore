import Foundation
import XCTest
@testable import AssistantCore

final class TaskSchedulerTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testSchedulerRunsWorkerStateSequence() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = makeInput()
        _ = try await fixture.queue.enqueue(input)
        let scheduler = TaskScheduler(queue: fixture.queue, workerID: "scheduler-test")

        let result = try await scheduler.processNext { task in
            XCTAssertEqual(task.id, input.id)
            return [.startProcessing, .generateReply, .requestSend, .sendVerified]
        }

        guard case let .completed(taskID, finalState) = result else {
            return XCTFail("expected completed result")
        }
        XCTAssertEqual(taskID, input.id)
        XCTAssertEqual(finalState, .sentVerified)
    }

    func testEmergencyPauseStopsClaiming() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.queue.enqueue(makeInput())
        let scheduler = TaskScheduler(queue: fixture.queue)
        await scheduler.setAutomaticRepliesPaused(true)

        let result = try await scheduler.processNext { _ in
            XCTFail("handler should not run while paused")
            return []
        }
        XCTAssertEqual(result, .paused)
        let metrics = try await fixture.queue.metrics()
        XCTAssertEqual(metrics.byState[TaskState.queued.rawValue], 1)
    }

    func testWorkerFailureEscalatesToManualReview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = makeInput()
        _ = try await fixture.queue.enqueue(input)
        let scheduler = TaskScheduler(queue: fixture.queue)

        let result = try await scheduler.processNext { _ in
            throw TaskQueueError.corruptPayload
        }
        guard case let .failedToManualReview(taskID, _) = result else {
            return XCTFail("expected manual review")
        }
        XCTAssertEqual(taskID, input.id)
        let stored = try await fixture.queue.task(id: input.id)
        XCTAssertEqual(stored?.state, .manualReview)
    }

    private func makeFixture() throws -> (
        directory: URL,
        queue: SQLiteTaskQueue
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cipher = try AESGCMTaskCipher(keyData: Data(repeating: 0x44, count: 32))
        let timestamp = fixedDate
        let queue = try SQLiteTaskQueue(
            databaseURL: directory.appendingPathComponent("tasks.sqlite"),
            cipher: cipher,
            clock: { timestamp }
        )
        return (directory, queue)
    }

    private func makeInput() -> QueueTaskInput {
        QueueTaskInput(
            eventID: "scheduler-event",
            idempotencyKey: "scheduler-key",
            platform: .qianniu,
            storeName: "测试店铺",
            payload: TaskPayload(
                notificationKey: "scheduler-notification",
                customerName: "客户甲",
                buyerQuestion: "什么时候发货",
                conversation: [
                    QueueConversationMessage(
                        side: .customer,
                        text: "什么时候发货",
                        observedAt: fixedDate
                    )
                ],
                orderInfo: nil,
                riskCategory: .normal,
                aiReason: "普通咨询",
                suggestedReply: "当天16:30前付款当天发货。"
            ),
            priority: .high,
            availableAt: fixedDate,
            createdAt: fixedDate
        )
    }
}
