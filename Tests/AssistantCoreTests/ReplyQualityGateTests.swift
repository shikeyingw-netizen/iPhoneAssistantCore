import XCTest
@testable import AssistantCore

final class ReplyQualityGateTests: XCTestCase {
    func testNormalReplyCanAutoSend() {
        let assessment = MerchantPolicy.assess("什么时候发货")
        let result = ReplyQualityGate.validate(
            "当天16:30前付款当天发货。",
            assessment: assessment
        )
        XCTAssertTrue(result.isSafe)
        XCTAssertFalse(result.manualReviewRequired)
        XCTAssertTrue(result.canAutoSend)
    }

    func testAISelfReferenceIsRejected() {
        let assessment = MerchantPolicy.assess("什么时候发货")
        let result = ReplyQualityGate.validate(
            "作为AI，我建议您尽快下单。",
            assessment: assessment
        )
        XCTAssertTrue(result.violations.contains(.containsAISelfReference))
        XCTAssertFalse(result.canAutoSend)
    }

    func testPIIIsRejected() {
        let assessment = MerchantPolicy.assess("发货时间")
        let result = ReplyQualityGate.validate(
            "请联系13812345678。",
            assessment: assessment
        )
        XCTAssertTrue(result.violations.contains(.containsPII))
        XCTAssertFalse(result.canAutoSend)
    }

    func testHighRiskReplyAlwaysRequiresManualReview() {
        let assessment = MerchantPolicy.assess("我要退款")
        let result = ReplyQualityGate.validate(
            "我先为您核实订单和物流状态。",
            assessment: assessment
        )
        XCTAssertTrue(result.manualReviewRequired)
        XCTAssertFalse(result.canAutoSend)
    }

    func testUnauthorizedPromiseIsRejected() {
        let assessment = MerchantPolicy.assess("我要退款")
        let result = ReplyQualityGate.validate(
            "放心，已经退款了。",
            assessment: assessment
        )
        XCTAssertTrue(result.violations.contains(.unauthorizedHighRiskPromise))
        XCTAssertFalse(result.canAutoSend)
    }

    func testWhitespaceIsNormalized() {
        let assessment = MerchantPolicy.assess("多久到")
        let result = ReplyQualityGate.validate(
            "省内约2天，\n省外3-5天。",
            assessment: assessment
        )
        XCTAssertEqual(result.normalizedReply, "省内约2天， 省外3-5天。")
    }

    func testStoreCatalogMatchesCurrentAccounts() {
        XCTAssertEqual(StoreCatalog.pinduoduoStores.count, 17)
        XCTAssertEqual(StoreCatalog.pinduoduoBundleIdentifier, "com.xunmeng.merchant")
        XCTAssertEqual(StoreCatalog.qianniuBundleIdentifier, "com.taobao.sellerplatform")
        XCTAssertEqual(StoreCatalog.deepSeekBundleIdentifier, "com.deepseek.chat")
    }
}
