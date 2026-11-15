import XCTest
@testable import AssistantCore

final class ManualTakeoverCenterTests: XCTestCase {
    private let fixedDate = manualTakeoverTestDate

    func testSubmissionCreatesRedactedLocalNotification() async throws {
        let center = ManualTakeoverCenter(clock: { manualTakeoverTestDate })
        let task = makeTask(
            question: "退款吧，电话13812345678，地址河南省洛阳市洛龙区开元大道100号2栋301"
        )

        let submission = try await center.submit(task)

        XCTAssertEqual(submission.task.status, .pendingReview)
        XCTAssertFalse(submission.notification.body.contains("13812345678"))
        XCTAssertFalse(submission.notification.body.contains("开元大道100号2栋301"))
        XCTAssertTrue(submission.notification.title.contains("拼多多"))
        let pending = await center.pendingTasks()
        XCTAssertEqual(pending.count, 1)
    }

    func testHighRiskMessageCannotSendBeforeApproval() async throws {
        let center = ManualTakeoverCenter(clock: { manualTakeoverTestDate })
        let task = makeTask(question: "我要退款")
        _ = try await center.submit(task)

        var canSend = await center.canSend(taskID: task.id)
        XCTAssertFalse(canSend)

        try await center.editReply(taskID: task.id, reply: "我先帮您核实订单和物流。")
        try await center.approve(taskID: task.id)

        canSend = await center.canSend(taskID: task.id)
        XCTAssertTrue(canSend)
        let approved = await center.task(id: task.id)
        XCTAssertEqual(approved?.status, .approvedToSend)
        XCTAssertEqual(approved?.approvedAt, fixedDate)
        XCTAssertTrue(
            approved?.auditTrail.contains(where: { $0.kind == .approved }) == true
        )
    }

    func testEmergencyPauseBlocksApprovedSend() async throws {
        let center = ManualTakeoverCenter(clock: { manualTakeoverTestDate })
        let task = makeTask(question: "可以改地址吗")
        _ = try await center.submit(task)
        try await center.approve(taskID: task.id)

        try await center.pauseAllAutomaticReplies()
        let paused = await center.isAutomationPaused
        var canSend = await center.canSend(taskID: task.id)
        XCTAssertTrue(paused)
        XCTAssertFalse(canSend)

        try await center.resumeAutomaticReplies()
        canSend = await center.canSend(taskID: task.id)
        XCTAssertTrue(canSend)
        let snapshot = await center.snapshot()
        XCTAssertTrue(
            snapshot.controlAuditTrail.contains(where: { $0.kind == .automationPaused })
        )
        XCTAssertTrue(
            snapshot.controlAuditTrail.contains(where: { $0.kind == .automationResumed })
        )
    }

    func testRejectedTaskCannotSend() async throws {
        let center = ManualTakeoverCenter(clock: { manualTakeoverTestDate })
        let task = makeTask(question: "这个是不是假货")
        _ = try await center.submit(task)
        try await center.reject(taskID: task.id, reason: "人工判定不发送")

        let stored = await center.task(id: task.id)
        let canSend = await center.canSend(taskID: task.id)
        XCTAssertEqual(stored?.status, .rejected)
        XCTAssertFalse(canSend)
    }

    func testUncertainSendIsNotTreatedAsApprovedToSend() async throws {
        let center = ManualTakeoverCenter(clock: { manualTakeoverTestDate })
        let task = makeTask(question: "退款申请")
        _ = try await center.submit(task)
        try await center.approve(taskID: task.id)
        try await center.markSendUncertain(taskID: task.id)

        let stored = await center.task(id: task.id)
        let canSend = await center.canSend(taskID: task.id)
        XCTAssertEqual(stored?.status, .sendUncertain)
        XCTAssertFalse(canSend)
    }

    func testKnowledgeRequiresExactQuestionAndManualReview() async throws {
        let center = ManualTakeoverCenter(clock: { manualTakeoverTestDate })
        let task = makeTask(question: "今天几点前付款能发货？")
        _ = try await center.submit(task)

        let entry = try await center.addKnowledge(
            taskID: task.id,
            answer: "当天16:30前付款当天发货。",
            source: .manualApproval
        )
        XCTAssertEqual(entry.version, 1)

        let exact = await center.knowledgeSuggestions(for: "今天几点前付款能发货？")
        XCTAssertEqual(exact.count, 1)
        XCTAssertTrue(exact[0].requiresManualReview)
        XCTAssertEqual(exact[0].entry.sourceTaskID, task.id)

        let related = await center.knowledgeSuggestions(for: "今天最晚什么时候付款能发货？")
        XCTAssertTrue(related.isEmpty)
    }

    func testKnowledgeUpdateRecordsSourceVersionAndTime() async throws {
        let center = ManualTakeoverCenter(clock: { manualTakeoverTestDate })
        let task = makeTask(question: "能试吃吗")
        _ = try await center.submit(task)
        _ = try await center.addKnowledge(
            taskID: task.id,
            answer: "可以试吃。",
            source: .manualApproval
        )
        let updated = try await center.addKnowledge(
            taskID: task.id,
            answer: "可以试吃，到货七天内不吃不满意包退。",
            source: .manualClarification
        )

        XCTAssertEqual(updated.version, 2)
        XCTAssertEqual(updated.sourceTaskID, task.id)
        XCTAssertEqual(updated.updatedAt, fixedDate)
    }

    func testSnapshotRestoresPendingTasksAndPauseState() async throws {
        let store = InMemoryTakeoverStore()
        let first = ManualTakeoverCenter(store: store, clock: { manualTakeoverTestDate })
        let task = makeTask(question: "我要改地址")
        _ = try await first.submit(task)
        try await first.pauseAllAutomaticReplies()

        let second = ManualTakeoverCenter(store: store, clock: { manualTakeoverTestDate })
        try await second.restore()
        let restored = await second.task(id: task.id)
        let paused = await second.isAutomationPaused
        XCTAssertEqual(restored?.status, .pendingReview)
        XCTAssertTrue(paused)
    }

    private func makeTask(question: String) -> TakeoverTask {
        TakeoverTask(
            source: .pinduoduo,
            storeName: "测试店铺",
            buyerName: "客户甲",
            buyerQuestion: question,
            originalConversation: [
                ChatMessage(side: .customer, text: question, observedAt: fixedDate)
            ],
            orderInfo: TakeoverOrderInfo(
                orderID: "ORDER-001",
                status: "已发货",
                carrier: "申通",
                trackingNumber: "777000000001"
            ),
            aiReason: "命中高风险规则",
            aiSuggestedReply: "我先帮您核实一下。",
            isHighRisk: true,
            createdAt: fixedDate
        )
    }
}

private let manualTakeoverTestDate = Date(timeIntervalSince1970: 1_800_000_000)

private actor InMemoryTakeoverStore: TakeoverStateStore {
    private var snapshot = TakeoverSnapshot()

    func load() async throws -> TakeoverSnapshot {
        snapshot
    }

    func save(_ snapshot: TakeoverSnapshot) async throws {
        self.snapshot = snapshot
    }
}
