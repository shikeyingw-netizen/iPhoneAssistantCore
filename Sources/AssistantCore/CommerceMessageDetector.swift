import Foundation

public enum CommerceMessageSource: String, Codable, Sendable {
    case notificationCenter
    case pinduoduoOverlay
    case pinduoduoPendingList
    case qianniuUnreadList
    case directChat
}

public struct DetectedCommerceMessage: Equatable, Sendable {
    public let platform: CommercePlatform
    public let storeName: String
    public let customerName: String
    public let text: String
    public let notificationKey: String
    public let source: CommerceMessageSource
    public let detectedAt: Date
    public let actionX: Double?
    public let actionY: Double?

    public init(
        platform: CommercePlatform,
        storeName: String,
        customerName: String,
        text: String,
        notificationKey: String,
        source: CommerceMessageSource,
        detectedAt: Date,
        actionX: Double? = nil,
        actionY: Double? = nil
    ) {
        self.platform = platform
        self.storeName = storeName
        self.customerName = customerName
        self.text = text
        self.notificationKey = notificationKey
        self.source = source
        self.detectedAt = detectedAt
        self.actionX = actionX
        self.actionY = actionY
    }
}

public enum CommerceNotificationParser {
    private static let pinduoduoPrefix = "拼多多商家版, "
    private static let qianniuPrefix = "千牛, "
    private static let timeOnlyPattern =
        #"^(?:现在|刚刚|今天|\d{1,2}:\d{2}|昨天(?: \d{1,2}:\d{2})?|星期[一二三四五六日天].*|\d+\s*(?:秒|分钟|小时|天)前)$"#

    private static let systemTitles = [
        "消息测试",
        "订单",
        "退款",
        "售后",
        "待发货提醒",
        "发货",
        "物流",
        "站内信",
        "活动",
        "大促",
        "商品",
        "抽检",
        "下架",
        "地址异常",
        "预警",
        "公告",
        "处罚",
        "官方通知",
        "店铺预警",
        "订单通知",
        "平台活动",
        "营销",
        "招商",
        "流量扶持",
        "客服机器人",
        "直播小二",
        "商家运营小二",
        "淘宝商家运营",
        "阿里认证",
    ]

    public static func parse(
        _ snapshot: AccessibilitySnapshot
    ) -> [DetectedCommerceMessage] {
        var output: [DetectedCommerceMessage] = []
        var seen: Set<String> = []

        for node in snapshot.nodes {
            guard node.identifier == "NotificationShortLookView" else {
                continue
            }
            let label = normalizeWhitespace(node.label)
            let platform: CommercePlatform
            let rest: String
            if label.hasPrefix(pinduoduoPrefix) {
                platform = .pinduoduo
                rest = String(label.dropFirst(pinduoduoPrefix.count))
            } else if label.hasPrefix(qianniuPrefix) {
                platform = .qianniu
                rest = String(label.dropFirst(qianniuPrefix.count))
            } else {
                continue
            }

            var parts = rest.components(separatedBy: ", ")
            if let first = parts.first, matches(first, timeOnlyPattern) {
                parts.removeFirst()
            }
            guard let title = parts.first, !title.isEmpty else {
                continue
            }
            parts.removeFirst()
            let body = normalizeWhitespace(parts.joined(separator: ", "))
            guard !body.isEmpty,
                  !isSystemNotification(title: title, body: body)
            else {
                continue
            }

            let key = StableIdentifier.hexDigest(
                platform.rawValue,
                normalizeIdentity(title),
                normalizeIdentity(body)
            )
            guard seen.insert(key).inserted else {
                continue
            }
            output.append(
                DetectedCommerceMessage(
                    platform: platform,
                    storeName: "\(platform.displayName)待核实店铺",
                    customerName: title,
                    text: body,
                    notificationKey: key,
                    source: .notificationCenter,
                    detectedAt: snapshot.capturedAt,
                    actionX: node.centerX,
                    actionY: node.centerY
                )
            )
        }
        return output
    }

    private static func isSystemNotification(
        title: String,
        body: String
    ) -> Bool {
        let combined = title + " " + body
        if systemTitles.contains(where: {
            title.localizedCaseInsensitiveContains($0)
        }) {
            return true
        }
        return MerchantPolicy.systemMarkers.contains {
            combined.contains($0)
        }
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeIdentity(_ text: String) -> String {
        normalizeWhitespace(text)
            .replacingOccurrences(
                of: #"\d{1,2}:\d{2}"#,
                with: "<time>",
                options: .regularExpression
            )
            .lowercased()
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }
}

public enum CommerceMessageDetector {
    private static let timerPattern =
        #"(?:\d+\s*(?:秒|分钟)后超时|即将超时|已等待(?:\s*\d+\s*(?:秒|分钟))?|待回复)"#
    private static let messageMarkers = Set([
        "已读",
        "未读",
        "已回复",
        "待回复",
        "下拉刷新",
        "没有更多消息",
        "主账号:",
        "店铺",
        "在线",
        "今天",
        "昨天",
    ])

    public static func parse(
        bundleID: String,
        snapshot: AccessibilitySnapshot
    ) -> [DetectedCommerceMessage] {
        switch bundleID {
        case "com.apple.springboard":
            return CommerceNotificationParser.parse(snapshot)
        case PinduoduoDriver.bundleID:
            return pinduoduoMessages(snapshot)
        case QianniuDriver.bundleID:
            return qianniuMessages(snapshot)
        default:
            return []
        }
    }

    public static func pinduoduoMessages(
        _ snapshot: AccessibilitySnapshot
    ) -> [DetectedCommerceMessage] {
        let overlays = pinduoduoOverlayMessages(snapshot)
        if !overlays.isEmpty {
            var output = overlays
            appendLatestPinduoduoMessage(
                from: snapshot,
                to: &output
            )
            return unique(output)
        }

        var output: [DetectedCommerceMessage] = []
        for row in PinduoduoPageParser.pendingRows(snapshot) {
            let text = clean(row.preview)
            guard !text.isEmpty,
                  !MerchantPolicy.containsAny(
                      text,
                      MerchantPolicy.systemMarkers
                  )
            else {
                continue
            }
            let key = StableIdentifier.hexDigest(
                "pinduoduo",
                normalizeIdentity(row.storeName),
                normalizeIdentity(text)
            )
            output.append(
                DetectedCommerceMessage(
                    platform: .pinduoduo,
                    storeName: row.storeName,
                    customerName: "待核实客户",
                    text: text,
                    notificationKey: key,
                    source: .pinduoduoPendingList,
                    detectedAt: snapshot.capturedAt,
                    actionX: row.centerX,
                    actionY: row.centerY
                )
            )
        }

        appendLatestPinduoduoMessage(from: snapshot, to: &output)
        return unique(output)
    }

    private static func appendLatestPinduoduoMessage(
        from snapshot: AccessibilitySnapshot,
        to output: inout [DetectedCommerceMessage]
    ) {
        if let latest = latestPinduoduoCustomerMessage(snapshot) {
            let key = StableIdentifier.hexDigest(
                "pinduoduo",
                normalizeIdentity(latest.customer),
                normalizeIdentity(latest.text)
            )
            output.append(
                DetectedCommerceMessage(
                    platform: .pinduoduo,
                    storeName: "拼多多当前店铺",
                    customerName: latest.customer,
                    text: latest.text,
                    notificationKey: key,
                    source: .directChat,
                    detectedAt: snapshot.capturedAt
                )
            )
        }
    }

    public static func qianniuMessages(
        _ snapshot: AccessibilitySnapshot
    ) -> [DetectedCommerceMessage] {
        var output = qianniuUnreadMessages(snapshot)
        if let latest = latestQianniuCustomerMessage(snapshot) {
            let key = StableIdentifier.hexDigest(
                "qianniu",
                normalizeIdentity(latest.customer),
                normalizeIdentity(latest.text)
            )
            output.append(
                DetectedCommerceMessage(
                    platform: .qianniu,
                    storeName: qianniuStoreName(snapshot),
                    customerName: latest.customer,
                    text: latest.text,
                    notificationKey: key,
                    source: .directChat,
                    detectedAt: snapshot.capturedAt
                )
            )
        }
        return unique(output)
    }

    private static func pinduoduoOverlayMessages(
        _ snapshot: AccessibilitySnapshot
    ) -> [DetectedCommerceMessage] {
        let actions = snapshot.nodes.filter {
            ($0.kind == "Button" || $0.kind == "Other")
                && $0.label.contains("立即回复")
                && $0.width >= 50
        }
        return actions.compactMap { action in
            let local = snapshot.nodes.filter {
                abs($0.centerY - action.centerY) <= 145
                    && abs($0.centerX - action.centerX) <= 360
            }
            let body = local
                .filter {
                    ($0.kind == "StaticText" || $0.kind == "Other")
                        && !$0.label.isEmpty
                        && $0.width >= 80
                        && $0.centerY >= action.centerY - 95
                        && $0.centerY <= action.centerY + 55
                        && !$0.label.contains("立即回复")
                        && !$0.label.contains("后超时")
                        && $0.label != "店铺"
                }
                .max(by: { $0.label.count < $1.label.count })
            guard let body else {
                return nil
            }

            let timerY = local
                .filter { matches($0.label, timerPattern) }
                .map(\.centerY)
                .min()
            let store = local
                .filter {
                    ($0.kind == "StaticText" || $0.kind == "Other")
                        && $0.width >= 30
                        && $0.label.count >= 2
                        && $0.label.count <= 24
                        && !$0.label.contains("立即回复")
                        && !matches($0.label, timerPattern)
                        && $0.label != "店铺"
                        && $0.centerY < body.centerY
                        && (timerY == nil || $0.centerY <= timerY! + 2)
                }
                .max(by: { $0.centerY < $1.centerY })?
                .label
            let text = clean(body.label)
            guard !text.isEmpty,
                  !MerchantPolicy.containsAny(
                      text,
                      MerchantPolicy.systemMarkers
                  )
            else {
                return nil
            }
            let storeName = store.map(clean) ?? "拼多多待核实店铺"
            let key = StableIdentifier.hexDigest(
                "pinduoduo",
                normalizeIdentity(storeName),
                normalizeIdentity(text)
            )
            return DetectedCommerceMessage(
                platform: .pinduoduo,
                storeName: storeName,
                customerName: "待核实客户",
                text: text,
                notificationKey: key,
                source: .pinduoduoOverlay,
                detectedAt: snapshot.capturedAt,
                actionX: action.centerX,
                actionY: action.centerY
            )
        }
    }

    private static func qianniuUnreadMessages(
        _ snapshot: AccessibilitySnapshot
    ) -> [DetectedCommerceMessage] {
        let store = qianniuStoreName(snapshot)
        return snapshot.nodes
            .filter {
                $0.kind == "Cell"
                    && $0.width >= 300
                    && (60...120).contains($0.height)
                    && $0.y >= 90
                    && $0.y < 800
            }
            .compactMap { cell in
                let nested = snapshot.nodes.filter {
                    contains(cell, $0.centerX, $0.centerY)
                }
                guard nested.contains(where: {
                    $0.label.trimmingCharacters(in: .whitespaces)
                        == "[未读]"
                }) else {
                    return nil
                }
                let customer = nested
                    .filter {
                        $0.kind == "StaticText"
                            && $0.x >= 55
                            && $0.x < 280
                            && $0.y < cell.y + cell.height * 0.42
                            && !messageMarkers.contains(clean($0.label))
                            && !isTimestamp($0.label)
                    }
                    .min(by: { $0.y < $1.y })?
                    .label
                let preview = nested
                    .filter {
                        ($0.kind == "StaticText" || $0.kind == "Other")
                            && $0.x >= 55
                            && $0.width >= 30
                            && $0.y >= cell.y + cell.height * 0.35
                            && $0.y < cell.y + cell.height
                            && !messageMarkers.contains(clean($0.label))
                            && !isTimestamp($0.label)
                            && !$0.label.hasPrefix("【即将超时】")
                    }
                    .max(by: { $0.width < $1.width })?
                    .label
                guard let customer, let preview else {
                    return nil
                }
                let text = clean(preview)
                guard !text.isEmpty,
                      !MerchantPolicy.containsAny(
                          text,
                          MerchantPolicy.systemMarkers
                      )
                else {
                    return nil
                }
                let key = StableIdentifier.hexDigest(
                    "qianniu",
                    normalizeIdentity(store),
                    normalizeIdentity(customer),
                    normalizeIdentity(text)
                )
                return DetectedCommerceMessage(
                    platform: .qianniu,
                    storeName: store,
                    customerName: clean(customer),
                    text: text,
                    notificationKey: key,
                    source: .qianniuUnreadList,
                    detectedAt: snapshot.capturedAt,
                    actionX: cell.centerX,
                    actionY: cell.centerY
                )
            }
    }

    private static func latestPinduoduoCustomerMessage(
        _ snapshot: AccessibilitySnapshot
    ) -> (customer: String, text: String)? {
        guard snapshot.source.contains("NavigationBar"),
              snapshot.source.contains("TextView"),
              snapshot.source.contains("订单"),
              !snapshot.source.contains("PMChatContainerView")
        else {
            return nil
        }
        let cells = snapshot.nodes.filter {
            $0.kind == "Cell" && $0.height >= 35 && $0.y >= 90
        }
        let messages = cells.compactMap {
            cell -> (x: Double, y: Double, text: String)? in
            let nested = snapshot.nodes.filter {
                contains(cell, $0.centerX, $0.centerY)
            }
            let images = nested.filter {
                $0.kind == "Image" && $0.width >= 20
            }
            guard let image = images.min(by: { $0.x < $1.x }) else {
                return nil
            }
            let texts = nested.filter {
                ($0.kind == "Other" || $0.kind == "StaticText")
                    && $0.x >= 45
                    && $0.width >= 20
                    && !$0.label.isEmpty
                    && !messageMarkers.contains(clean($0.label))
                    && !isTimestamp($0.label)
            }
            guard let text = texts.max(by: { $0.y < $1.y }) else {
                return nil
            }
            return (image.x, cell.y, clean(text.label))
        }
        guard let latest = messages.max(by: { $0.y < $1.y }),
              latest.x < 100
        else {
            return nil
        }
        return (pinduoduoCustomerName(snapshot), latest.text)
    }

    private static func latestQianniuCustomerMessage(
        _ snapshot: AccessibilitySnapshot
    ) -> (customer: String, text: String)? {
        guard snapshot.nodes.contains(where: {
            $0.kind == "Button" && $0.label == "back"
        }) else {
            return nil
        }
        let customer = snapshot.nodes
            .filter {
                $0.kind == "Button"
                    && $0.x >= 40
                    && $0.x < 220
                    && $0.y < 130
                    && !$0.label.isEmpty
                    && $0.label != "back"
                    && $0.label != "mine_circle"
                    && !$0.label.hasPrefix("http")
            }
            .min(by: { $0.x < $1.x })?
            .label ?? "待核实客户"
        let messages = snapshot.nodes.filter {
            ($0.kind == "Other" || $0.kind == "StaticText")
                && $0.x >= 55
                && $0.x < 335
                && $0.y >= 100
                && $0.y < 700
                && $0.width >= 20
                && !$0.label.isEmpty
                && !messageMarkers.contains(clean($0.label))
                && !isTimestamp($0.label)
        }
        guard let latest = messages.max(by: { $0.y < $1.y }),
              latest.x < 190
        else {
            return nil
        }
        return (clean(customer), clean(latest.label))
    }

    private static func pinduoduoCustomerName(
        _ snapshot: AccessibilitySnapshot
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"NavigationBar, id: '([^']+)'"#
        ) else {
            return "待核实客户"
        }
        let range = NSRange(
            snapshot.source.startIndex..<snapshot.source.endIndex,
            in: snapshot.source
        )
        guard let match = expression.firstMatch(
            in: snapshot.source,
            range: range
        ), let valueRange = Range(match.range(at: 1), in: snapshot.source) else {
            return "待核实客户"
        }
        return String(snapshot.source[valueRange])
            .replacingOccurrences(
                of: #"\(\d+\)$"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func qianniuStoreName(
        _ snapshot: AccessibilitySnapshot
    ) -> String {
        snapshot.nodes
            .filter {
                $0.kind == "StaticText"
                    && $0.x >= 55
                    && $0.x < 300
                    && $0.y >= 25
                    && $0.y < 95
                    && $0.label.count >= 2
                    && !messageMarkers.contains(clean($0.label))
            }
            .max(by: { $0.label.count < $1.label.count })?
            .label ?? "千牛当前店铺"
    }

    private static func contains(
        _ container: AccessibilityNode,
        _ x: Double,
        _ y: Double
    ) -> Bool {
        x >= container.x
            && x <= container.x + container.width
            && y >= container.y
            && y <= container.y + container.height
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }

    private static func isTimestamp(_ text: String) -> Bool {
        matches(
            clean(text),
            #"^(?:\d{1,2}:\d{2}|今天|昨天|星期[一二三四五六日天]|\d{2}/\d{2}/\d{2}).*$"#
        )
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeIdentity(_ text: String) -> String {
        clean(text)
            .replacingOccurrences(
                of: #"\d{1,2}:\d{2}"#,
                with: "<time>",
                options: .regularExpression
            )
            .lowercased()
    }

    private static func unique(
        _ messages: [DetectedCommerceMessage]
    ) -> [DetectedCommerceMessage] {
        var seen = Set<String>()
        return messages.filter {
            seen.insert(
                "\($0.platform.rawValue)|\($0.notificationKey)"
            ).inserted
        }
    }
}
