import XCTest
@testable import AssistantCore

final class MerchantPolicyTests: XCTestCase {
    func testCustomerServiceTestMessageHasDeterministicReply() {
        XCTAssertEqual(
            MerchantPolicy.deterministicReply(
                for: "客服自动回复测试2，请回复测试成功"
            ),
            "客服测试成功"
        )
    }

    func testShippingQuestionUsesKnownRule() {
        let result = MerchantPolicy.response(for: "今天下单什么时候发货？")
        XCTAssertEqual(result.0.category, .normal)
        XCTAssertFalse(result.0.requiresHumanReview)
        XCTAssertEqual(
            result.1,
            "亲，当天16:30前付款当天发货，16:30后付款次日发货哦。"
        )
    }

    func testRefundRequiresHumanReview() {
        let result = MerchantPolicy.response(for: "这个我要退款")
        XCTAssertEqual(result.0.category, .refund)
        XCTAssertTrue(result.0.requiresHumanReview)
        XCTAssertEqual(
            result.1,
            "亲，收到您的退款问题了，我先为您核实订单和物流状态，确认后马上回复您～"
        )
    }

    func testAddressChangeRequestsCompleteInformation() {
        let result = MerchantPolicy.response(for: "地址填错了，帮我改地址")
        XCTAssertEqual(result.0.category, .addressChange)
        XCTAssertTrue(result.0.requiresHumanReview)
        XCTAssertTrue(result.1?.contains("新收件人姓名、电话和完整地址") == true)
    }

    func testPlatformNoticeIsNotAutoReplied() {
        let result = MerchantPolicy.response(for: "直播小二：双11商家流量扶持计划")
        XCTAssertEqual(result.0.category, .platformNotice)
        XCTAssertFalse(result.0.shouldAutoReply)
        XCTAssertNil(result.1)
    }

    func testNoLiveBirdAndFormulaRules() {
        XCTAssertEqual(
            MerchantPolicy.deterministicReply(for: "你们卖活体鹩哥吗"),
            "亲，我们店铺主营鹩哥、八哥鸟粮及宠物用品，暂时没有活体鸟出售哦。"
        )
        XCTAssertEqual(
            MerchantPolicy.deterministicReply(for: "A型和B型有什么区别"),
            "亲，A/B型配料基本一样，主要是比例不同；价格高的营养比例更高，B型的肉比例更多一些。"
        )
    }

    func testPromptContainsSafetyAndLatestConversation() {
        let context = ConversationContext(
            platform: .pinduoduo,
            storeName: "测试店铺",
            customerName: "客户甲",
            messages: [
                ChatMessage(side: .customer, text: "发货时间是什么时候"),
                ChatMessage(side: .merchant, text: MerchantPolicy.shippingCutoff),
                ChatMessage(side: .customer, text: "发什么快递"),
            ]
        )
        let prompt = DeepSeekPromptBuilder.prompt(for: context)
        XCTAssertTrue(prompt.contains("16:30"))
        XCTAssertTrue(prompt.contains("不卖活体鸟"))
        XCTAssertTrue(prompt.contains("客户: 发什么快递"))
        XCTAssertTrue(prompt.contains("禁止编造"))
    }

    func testPIISanitizer() {
        let input = "电话13812345678，地址河南省洛阳市洛龙区开元大道100号2栋301，身份证410000200001011234"
        let output = PIISanitizer.sanitize(input)
        XCTAssertFalse(output.contains("13812345678"))
        XCTAssertFalse(output.contains("410000200001011234"))
        XCTAssertFalse(output.contains("开元大道100号2栋301"))
        XCTAssertTrue(output.contains("138****5678"))
    }

    func testIdempotencyKeyIsStable() {
        let first = StableIdentifier.messageKey(
            platform: .pinduoduo,
            storeName: "店铺",
            customerName: "客户",
            customerText: "你好",
            notificationKey: "notice"
        )
        let second = StableIdentifier.messageKey(
            platform: .pinduoduo,
            storeName: "店铺",
            customerName: "客户",
            customerText: "你好",
            notificationKey: "notice"
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 24)
    }
}
