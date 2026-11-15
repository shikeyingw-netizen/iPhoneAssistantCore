import Foundation
import XCTest
@testable import AssistantCore

final class WeChatLogisticsCoordinatorTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = LogisticsPolicy(
        groups: [
            .sto: "申通",
            .jnt: "极兔",
        ]
    )

    func testInterceptCreatesExactDraftAwaitingConfirmation() async throws {
        let coordinator = makeCoordinator()
        let draft = try await coordinator.prepareIntercept(order: stoOrder)

        XCTAssertEqual(draft.status, .awaitingConfirmation)
        XCTAssertEqual(draft.groupName, "申通")
        XCTAssertEqual(draft.message, "777000000001 拦截")
    }

    func testAddressChangeUsesExactGroupAndFullMessage() async throws {
        let coordinator = makeCoordinator()
        let draft = try await coordinator.prepareAddressChange(
            order: jntOrder,
            address: address
        )

        XCTAssertEqual(draft.groupName, "极兔")
        XCTAssertTrue(draft.message.contains("JT000000000002 改地址"))
        XCTAssertTrue(draft.message.contains("张三 13800000000"))
        XCTAssertEqual(draft.status, .awaitingConfirmation)
    }

    func testApprovalIsRequiredAndPreservesExactMessage() async throws {
        let coordinator = makeCoordinator()
        let draft = try await coordinator.prepareIntercept(order: stoOrder)

        let approved = try await coordinator.approve(
            draftID: draft.id,
            approvedBy: "operator"
        )
        let stored = await coordinator.draft(id: draft.id)

        XCTAssertEqual(approved.groupName, "申通")
        XCTAssertEqual(approved.message, "777000000001 拦截")
        XCTAssertEqual(stored?.status, .approved)
        XCTAssertEqual(stored?.approvedBy, "operator")
    }

    func testDuplicateActionReturnsSameDraft() async throws {
        let coordinator = makeCoordinator()
        let first = try await coordinator.prepareIntercept(order: stoOrder)
        let second = try await coordinator.prepareIntercept(order: stoOrder)

        XCTAssertEqual(first.id, second.id)
    }

    func testIncompleteAddressIsBlocked() async {
        let coordinator = makeCoordinator()

        do {
            _ = try await coordinator.prepareAddressChange(
                order: jntOrder,
                address: NewRecipientAddress(
                    recipientName: "王五",
                    phone: "",
                    province: "河南省",
                    city: "洛阳市",
                    district: "",
                    streetAddress: "某路"
                )
            )
            XCTFail("incomplete address must be blocked")
        } catch let error as WeChatLogisticsError {
            guard case let .blocked(reason, missing) = error else {
                return XCTFail("unexpected error")
            }
            XCTAssertEqual(reason, "地址信息不完整")
            XCTAssertTrue(missing.contains("联系电话"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUncertainSendCannotBeMarkedVerifiedFromAwaitingState() async throws {
        let coordinator = makeCoordinator()
        let draft = try await coordinator.prepareIntercept(order: stoOrder)

        do {
            try await coordinator.markSentVerified(draftID: draft.id)
            XCTFail("awaiting confirmation must not be markable as sent")
        } catch {
            XCTAssertEqual(
                error as? WeChatLogisticsError,
                .invalidState
            )
        }
    }

    private func makeCoordinator() -> WeChatLogisticsCoordinator {
        WeChatLogisticsCoordinator(
            policy: policy,
            clock: { fixedDate }
        )
    }

    private var stoOrder: OrderSnapshot {
        OrderSnapshot(
            orderID: "ORDER-STO",
            buyerID: "BUYER-STO",
            status: .shipped,
            carrierLabel: "申通快递",
            trackingNumber: "777000000001"
        )
    }

    private var jntOrder: OrderSnapshot {
        OrderSnapshot(
            orderID: "ORDER-JNT",
            buyerID: "BUYER-JNT",
            status: .shipped,
            carrierLabel: "极兔速递",
            trackingNumber: "JT000000000002"
        )
    }

    private var address: NewRecipientAddress {
        NewRecipientAddress(
            recipientName: "张三",
            phone: "13800000000",
            province: "河南省",
            city: "洛阳市",
            district: "洛龙区",
            streetAddress: "开元大道100号2栋301"
        )
    }
}
