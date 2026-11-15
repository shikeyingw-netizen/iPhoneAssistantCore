import XCTest
@testable import AssistantCore

final class LogisticsGuardTests: XCTestCase {
    private let policy = LogisticsPolicy(
        groups: [
            .sto: "申通央科鸟食群",
            .jnt: "极兔测试群",
        ]
    )

    func testSTOIntercept() {
        let decision = policy.intercept(order(carrier: "申通快递", tracking: "777000000001"))
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.groupName, "申通央科鸟食群")
        XCTAssertEqual(decision.courierMessage, "777000000001 拦截")
    }

    func testJNTIntercept() {
        let decision = policy.intercept(order(carrier: "极兔速递", tracking: "JT000000000002"))
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.groupName, "极兔测试群")
        XCTAssertEqual(decision.courierMessage, "JT000000000002 拦截")
    }

    func testAddressChange() {
        let decision = policy.changeAddress(
            order(carrier: "申通快递", tracking: "777000000003"),
            address: completeAddress
        )
        XCTAssertTrue(decision.allowed)
        XCTAssertTrue(decision.courierMessage.contains("改地址 + 张三"))
        XCTAssertTrue(decision.courierMessage.contains("河南省洛阳市洛龙区"))
    }

    func testIncompleteAddress() {
        let decision = policy.changeAddress(
            order(carrier: "极兔速递", tracking: "JT000000000004"),
            address: NewRecipientAddress(
                recipientName: "王五",
                phone: "",
                province: "河南省",
                city: "洛阳市",
                district: "",
                streetAddress: "某路"
            )
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "地址信息不完整")
        XCTAssertTrue(decision.missingFields.contains("联系电话"))
        XCTAssertTrue(decision.missingFields.contains("区县"))
        XCTAssertTrue(decision.missingFields.contains("详细地址"))
    }

    func testSignedOrderIsBlocked() {
        let decision = policy.intercept(
            order(status: .signed, carrier: "申通快递", tracking: "777000000005")
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(decision.reason.contains("已签收"))
    }

    func testDuplicateRefundIsBlocked() {
        let decision = policy.intercept(
            order(
                carrier: "申通快递",
                tracking: "777000000006",
                refundPending: true,
                refundHistoryCount: 2
            )
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(decision.reason.contains("重复退款"))
    }

    func testMissingGroupConfigurationIsBlocked() {
        let noGroupPolicy = LogisticsPolicy(groups: [:])
        let decision = noGroupPolicy.intercept(
            order(carrier: "极兔速递", tracking: "JT000000000007")
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "快递群名称尚未配置")
    }

    func testFingerprintIsStable() {
        let value = order(carrier: "申通快递", tracking: "777000000008")
        XCTAssertEqual(
            policy.fingerprint(order: value, action: .intercept),
            policy.fingerprint(order: value, action: .intercept)
        )
        XCTAssertNotEqual(
            policy.fingerprint(order: value, action: .intercept),
            policy.fingerprint(order: value, action: .addressChange)
        )
    }

    private var completeAddress: NewRecipientAddress {
        NewRecipientAddress(
            recipientName: "张三",
            phone: "13800000000",
            province: "河南省",
            city: "洛阳市",
            district: "洛龙区",
            streetAddress: "开元大道100号2栋301"
        )
    }

    private func order(
        status: OrderStatus = .shipped,
        carrier: String,
        tracking: String,
        refundPending: Bool = false,
        refundHistoryCount: Int = 0
    ) -> OrderSnapshot {
        OrderSnapshot(
            orderID: "SYNTH-\(tracking)",
            buyerID: "BUYER-\(tracking)",
            status: status,
            carrierLabel: carrier,
            trackingNumber: tracking,
            refundPending: refundPending,
            refundHistoryCount: refundHistoryCount
        )
    }
}
