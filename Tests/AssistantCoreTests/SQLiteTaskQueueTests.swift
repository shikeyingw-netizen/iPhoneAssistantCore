import Foundation
import XCTest
@testable import AssistantCore

final class SQLiteTaskQueueTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testEnqueuePersistsEncryptedPayloadAndDeduplicates() async throws {
        let fixture = try makeQueue()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let queue = fixture.queue
        let input = makeInput(
            key: "event-1",
            question: "电话13812345678，地址河南省洛阳市洛龙区开元大道100号2栋301"
        )

        let first = try await queue.enqueue(input)
        let second = try await queue.enqueue(
            QueueTaskInput(
                eventID: "different-event",
                idempotencyKey: "event-1",
                platform: .pinduoduo,
                storeName: "测试店铺",
                payload: input.payload,
                createdAt: fixedDate
            )
        )

        guard case let .inserted(inserted) = first else {
            return XCTFail("first enqueue should insert")
        }
        guard case let .duplicate(duplicate) = second else {
            return XCTFail("second enqueue should deduplicate")
        }
        XCTAssertEqual(inserted.id, duplicate.id)
        let metrics = try await queue.metrics()
        XCTAssertEqual(metrics.total, 1)

        let databaseBytes = try Data(contentsOf: fixture.databaseURL)
        XCTAssertNil(databaseBytes.range(of: Data("13812345678".utf8)))
        XCTAssertNil(databaseBytes.range(of: Data("开元大道100号2栋301".utf8)))
        XCTAssertNotNil(databaseBytes.range(of: Data("测试店铺".utf8)))
    }

    func testClaimHonorsPriority() async throws {
        let fixture = try makeQueue()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.queue.enqueue(
            makeInput(key: "normal", priority: .normal, createdAt: fixedDate)
        )
        _ = try await fixture.queue.enqueue(
            makeInput(
                key: "high",
                priority: .high,
                createdAt: fixedDate.addingTimeInterval(1),
                availableAt: fixedDate
            )
        )

        let claimed = try await fixture.queue.claimNext(workerID: "test")
        XCTAssertEqual(claimed?.idempotencyKey, "high")
        XCTAssertEqual(claimed?.state, .claimed)
        XCTAssertEqual(claimed?.leaseOwner, "test")
    }

    func testRestartRecoveryNeverRequeuesSendPending() async throws {
        let fixture = try makeQueue()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let queue = fixture.queue
        _ = try await queue.enqueue(makeInput(key: "send-pending"))
        let claimedOptional = try await queue.claimNext(workerID: "test")
        let claimed = try XCTUnwrap(claimedOptional)
        _ = try await queue.apply(taskID: claimed.id, event: .startProcessing)
        _ = try await queue.apply(taskID: claimed.id, event: .generateReply)
        _ = try await queue.apply(taskID: claimed.id, event: .requestSend)

        let report = try await queue.recoverAfterRestart()
        let recovered = try await queue.task(id: claimed.id)
        XCTAssertEqual(report.markedSendUncertain, 1)
        XCTAssertEqual(recovered?.state, .sendUncertain)
        let nextClaim = try await queue.claimNext(workerID: "test")
        XCTAssertNil(nextClaim)
    }

    func testRestartMovesInProgressTaskToManualReview() async throws {
        let fixture = try makeQueue()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let queue = fixture.queue
        _ = try await queue.enqueue(makeInput(key: "in-progress"))
        let claimedOptional = try await queue.claimNext(workerID: "test")
        let claimed = try XCTUnwrap(claimedOptional)
        _ = try await queue.apply(taskID: claimed.id, event: .startProcessing)

        let report = try await queue.recoverAfterRestart()
        let recovered = try await queue.task(id: claimed.id)
        XCTAssertEqual(report.movedToManualReview, 1)
        XCTAssertEqual(recovered?.state, .manualReview)
        let manual = try await queue.manualReviewTasks()
        XCTAssertEqual(manual.map(\.id), [claimed.id])
    }

    func testTaskSurvivesQueueReopen() async throws {
        let fixture = try makeQueue()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = makeInput(key: "reopen")
        _ = try await fixture.queue.enqueue(input)

        let reopened = try SQLiteTaskQueue(
            databaseURL: fixture.databaseURL,
            cipher: fixture.cipher,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let restored = try await reopened.task(id: input.id)
        XCTAssertEqual(restored?.idempotencyKey, "reopen")
        XCTAssertEqual(restored?.payload.buyerQuestion, input.payload.buyerQuestion)
    }

    func testStateUnknownCannotBlindlyRequestSecondSend() async throws {
        let fixture = try makeQueue()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let queue = fixture.queue
        _ = try await queue.enqueue(makeInput(key: "uncertain"))
        let claimedOptional = try await queue.claimNext(workerID: "test")
        let claimed = try XCTUnwrap(claimedOptional)
        _ = try await queue.apply(taskID: claimed.id, event: .startProcessing)
        _ = try await queue.apply(taskID: claimed.id, event: .generateReply)
        _ = try await queue.apply(taskID: claimed.id, event: .requestSend)
        _ = try await queue.apply(taskID: claimed.id, event: .sendNotVerified)

        do {
            _ = try await queue.apply(taskID: claimed.id, event: .requestSend)
            XCTFail("uncertain send must not be retried")
        } catch {
            XCTAssertEqual(
                error as? TaskTransitionError,
                TaskTransitionError.uncertainSendCannotBeRetried
            )
        }
    }

    private func makeQueue() throws -> (
        directory: URL,
        databaseURL: URL,
        queue: SQLiteTaskQueue,
        cipher: AESGCMTaskCipher
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("tasks.sqlite")
        let cipher = try AESGCMTaskCipher(keyData: Data(repeating: 0x42, count: 32))
        let timestamp = fixedDate
        let queue = try SQLiteTaskQueue(
            databaseURL: databaseURL,
            cipher: cipher,
            clock: { timestamp }
        )
        return (directory, databaseURL, queue, cipher)
    }

    private func makeInput(
        key: String,
        priority: TakeoverPriority = .normal,
        question: String = "什么时候发货",
        createdAt: Date? = nil,
        availableAt: Date? = nil
    ) -> QueueTaskInput {
        let timestamp = createdAt ?? fixedDate
        return QueueTaskInput(
            eventID: "event-\(key)",
            idempotencyKey: key,
            platform: .pinduoduo,
            storeName: "测试店铺",
            payload: TaskPayload(
                notificationKey: key,
                customerName: "客户甲",
                buyerQuestion: question,
                conversation: [
                    QueueConversationMessage(
                        side: .customer,
                        text: question,
                        observedAt: timestamp
                    )
                ],
                orderInfo: QueueOrderInfo(
                    orderID: "ORDER-001",
                    status: "已发货",
                    carrier: "申通",
                    trackingNumber: "777000000001"
                ),
                riskCategory: .normal,
                aiReason: "普通咨询",
                suggestedReply: "当天16:30前付款当天发货。"
            ),
            priority: priority,
            availableAt: availableAt ?? timestamp,
            createdAt: timestamp
        )
    }
}
