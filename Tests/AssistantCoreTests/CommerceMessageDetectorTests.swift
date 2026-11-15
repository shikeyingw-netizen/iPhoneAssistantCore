import Foundation
import XCTest
@testable import AssistantCore

final class CommerceMessageDetectorTests: XCTestCase {
    func testNotificationCenterParsesPinduoduoAndQianniuCustomerMessages() {
        let snapshot = AccessibilityTreeParser.parse(
            notificationSource(),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let messages = CommerceNotificationParser.parse(snapshot)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.platform), [.pinduoduo, .qianniu])
        XCTAssertEqual(messages[0].customerName, "买家甲")
        XCTAssertEqual(messages[0].text, "请问今天就发货吗")
        XCTAssertEqual(messages[1].customerName, "买家乙")
        XCTAssertEqual(messages[1].text, "A型和B型有什么区别")
    }

    func testNotificationCenterIgnoresPlatformAndMarketingNotifications() {
        let source = notificationSource() + """

          Type83, label: '拼多多商家版, 1分钟前, 待发货提醒, 您有一笔新的待发货订单。', id: 'NotificationShortLookView', {{10, 700}, {370, 66}}
          Type83, label: '千牛, 2分钟前, 直播小二, 双11活动开始报名。', id: 'NotificationShortLookView', {{10, 760}, {370, 66}}
        """

        let messages = CommerceNotificationParser.parse(
            AccessibilityTreeParser.parse(source)
        )

        XCTAssertEqual(messages.count, 2)
    }

    func testPinduoduoOverlayFindsStoreBodyAndReplyAction() {
        let source = """
        Application, label: '拼多多商家版', {{0, 0}, {390, 844}}
          StaticText, label: '中成商贸城', {{86, 64}, {90, 20}}
          StaticText, label: '店铺', {{180, 64}, {30, 18}}
          StaticText, label: '56秒后超时', {{285, 64}, {80, 20}}
          StaticText, label: '客服自动回复测试1，请回复测试成功', {{38, 101}, {250, 20}}
          Button, label: '立即回复', {{285, 91}, {82, 35}}
        """

        let messages = CommerceMessageDetector.pinduoduoMessages(
            AccessibilityTreeParser.parse(source)
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].storeName, "中成商贸城")
        XCTAssertEqual(
            messages[0].text,
            "客服自动回复测试1，请回复测试成功"
        )
        XCTAssertEqual(messages[0].source, .pinduoduoOverlay)
        XCTAssertEqual(messages[0].actionX, 326)
        XCTAssertEqual(messages[0].actionY, 108.5)
    }

    func testQianniuUnreadConversationIsDetectedWithPreview() {
        let source = """
        Application, label: '千牛', {{0, 0}, {390, 844}}
          StaticText, label: '中星商贸城', {{75, 47}, {110, 20}}
          Button, label: '消息', {{80, 762}, {74, 48}}
          Cell, {{0, 461}, {390, 74}}
            StaticText, label: '[未读]', {{67, 500}, {38, 17}}
            StaticText, label: '不生产了', {{108, 500}, {273, 17}}
            StaticText, label: '26/11/06', {{329, 473}, {48, 14}}
            StaticText, label: '杨杨建军军', {{67, 473}, {79, 19}}
        """

        let messages = CommerceMessageDetector.qianniuMessages(
            AccessibilityTreeParser.parse(source)
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].platform, .qianniu)
        XCTAssertEqual(messages[0].storeName, "中星商贸城")
        XCTAssertEqual(messages[0].customerName, "杨杨建军军")
        XCTAssertEqual(messages[0].text, "不生产了")
        XCTAssertEqual(messages[0].source, .qianniuUnreadList)
    }

    func testQianniuReadConversationRowIsStillAddressable() {
        let source = """
        Application, label: '千牛', {{0, 0}, {390, 844}}
          StaticText, label: '中星商贸城', {{75, 47}, {110, 20}}
          Cell, {{0, 461}, {390, 74}}
            StaticText, label: '[已读]', {{67, 500}, {38, 17}}
            StaticText, label: '客服自动回复测试7，请回复测试成功', {{108, 500}, {273, 17}}
            StaticText, label: '今天 23:43', {{329, 473}, {48, 14}}
            StaticText, label: 'tb089909406', {{67, 473}, {79, 19}}
        """

        let messages = CommerceMessageDetector.qianniuMessages(
            AccessibilityTreeParser.parse(source)
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].customerName, "tb089909406")
        XCTAssertEqual(
            messages[0].text,
            "客服自动回复测试7，请回复测试成功"
        )
    }

    func testQianniuComposerToolbarIsNotTreatedAsCustomerMessage() {
        let source = """
        Application, label: '千牛', {{0, 0}, {390, 844}}
          Button, label: 'back', {{12, 57}, {24, 24}}
          Button, label: 'tb089909406', {{55, 59}, {110, 21}}
          Cell, {{0, 236}, {390, 132}}
            Image, {{12, 277}, {34, 34}}
            StaticText, label: 'tb089909406', {{56, 277}, {84, 14}}
            Other, label: '客服自动回复测试10，请回复测试成功', {{67, 306}, {254, 42}}
          Cell, {{0, 379}, {100, 40}}
            Other, label: '邀请下单', {{8, 388}, {89, 31}}
          Cell, {{100, 379}, {69, 40}}
            Other, label: '相册', {{103, 388}, {63, 31}}
          Cell, {{170, 379}, {100, 40}}
            Other, label: '小额打款', {{173, 388}, {89, 31}}
          TextView, {{78, 429}, {168, 37}}
        """

        let messages = CommerceMessageDetector.qianniuMessages(
            AccessibilityTreeParser.parse(source)
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].source, .directChat)
        XCTAssertEqual(
            messages[0].text,
            "客服自动回复测试10，请回复测试成功"
        )
    }

    func testPinduoduoDirectChatUsesLatestCustomerMessage() {
        let source = """
        Application, label: '拼多多商家版', {{0, 0}, {390, 844}}
          NavigationBar, id: '客户甲', {{0, 47}, {390, 44}}
            StaticText, label: '订单', {{306, 73}, {20, 14}}
          Cell, {{0, 500}, {390, 70}}
            Image, {{15, 510}, {40, 40}}
            StaticText, label: '客户甲', {{70, 510}, {50, 18}}
            Other, label: '请问今天能发货吗', {{70, 540}, {150, 20}}
          TextView, {{57, 704}, {235, 36}}
        """

        let messages = CommerceMessageDetector.pinduoduoMessages(
            AccessibilityTreeParser.parse(source)
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].customerName, "客户甲")
        XCTAssertEqual(messages[0].text, "请问今天能发货吗")
        XCTAssertEqual(messages[0].source, .directChat)
    }

    func testRenderedBannerTextIsDetectedWhenAccessibilityTreeOmitsIt() {
        let items = [
            VisibleTextItem(
                label: "拼多多商家版",
                x: 71,
                y: 53,
                width: 91,
                height: 16,
                confidence: 1
            ),
            VisibleTextItem(
                label: "[2条]**：客服自动回复测试2，请回复",
                x: 72,
                y: 70,
                width: 254,
                height: 20,
                confidence: 0.5
            ),
            VisibleTextItem(
                label: "测试成功",
                x: 71,
                y: 88,
                width: 60,
                height: 16,
                confidence: 0.5
            ),
            VisibleTextItem(
                label: "1分钟前",
                x: 316,
                y: 54,
                width: 48,
                height: 15,
                confidence: 1
            ),
        ]

        let messages = CommerceBannerTextParser.parse(
            items,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].platform, .pinduoduo)
        XCTAssertEqual(
            messages[0].text,
            "[2条]**：客服自动回复测试2，请回复测试成功"
        )
        XCTAssertEqual(messages[0].actionX, 195)
    }

    func testHeadlessBannerUsesMerchantBadgeAsPlatformMarker() {
        let items = [
            VisibleTextItem(
                label: "**",
                x: 72,
                y: 58,
                width: 13,
                height: 7,
                confidence: 0.3
            ),
            VisibleTextItem(
                label: "商家版",
                x: 32,
                y: 85,
                width: 18,
                height: 7,
                confidence: 1
            ),
            VisibleTextItem(
                label: "客服自动回复测试4，请回复测试成功",
                x: 71,
                y: 74,
                width: 250,
                height: 18,
                confidence: 0.5
            ),
            VisibleTextItem(
                label: "1分钟前",
                x: 316,
                y: 54,
                width: 48,
                height: 15,
                confidence: 1
            ),
        ]

        let messages = CommerceBannerTextParser.parse(
            items,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].platform, .pinduoduo)
        XCTAssertEqual(
            messages[0].text,
            "客服自动回复测试4，请回复测试成功"
        )
    }

    private func notificationSource() -> String {
        """
        Application, label: ' ', {{0, 0}, {390, 844}}
          Type83, label: '拼多多商家版, 刚刚, 买家甲, 请问今天就发货吗', id: 'NotificationShortLookView', {{10, 160}, {370, 66}}
          Type83, label: '千牛, 1分钟前, 买家乙, A型和B型有什么区别', id: 'NotificationShortLookView', {{10, 230}, {370, 66}}
        """
    }
}
