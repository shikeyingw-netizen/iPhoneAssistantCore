import Foundation

public struct PinduoduoPendingRow: Equatable, Sendable {
    public let section: String
    public let storeName: String
    public let preview: String
    public let marker: String
    public let identity: String
    public let centerX: Double
    public let centerY: Double

    public init(
        section: String,
        storeName: String,
        preview: String,
        marker: String,
        identity: String,
        centerX: Double,
        centerY: Double
    ) {
        self.section = section
        self.storeName = storeName
        self.preview = preview
        self.marker = marker
        self.identity = identity
        self.centerX = centerX
        self.centerY = centerY
    }
}

public enum PinduoduoSurface: Equatable, Sendable {
    case pendingList([PinduoduoPendingRow])
    case directChat(customer: String)
    case unknown
}

public enum PinduoduoPageParser {
    private static let otherStoreHeaderPattern =
        #"^其他店铺消息(?:\s*\((\d+)\))?$"#
    private static let anySectionHeaderPattern = #"^[^|]{1,24}\(\d+\)$"#
    private static let navigationIDPattern =
        #"NavigationBar, id: '([^']+)'"#

    public static func parse(_ snapshot: AccessibilitySnapshot) -> PinduoduoSurface {
        if isDirectChat(snapshot) {
            return .directChat(customer: customerName(snapshot))
        }
        let rows = pendingRows(snapshot)
        return rows.isEmpty ? .unknown : .pendingList(rows)
    }

    public static func pendingRows(
        _ snapshot: AccessibilitySnapshot
    ) -> [PinduoduoPendingRow] {
        let sectionHeaders = snapshot.nodes
            .filter {
                matches($0.label, pattern: anySectionHeaderPattern)
            }
            .sorted { $0.y < $1.y }
        let otherSections = sectionHeaders.compactMap {
            node -> (header: AccessibilityNode, endY: Double, count: Int)? in
            guard let captures = regexCaptures(
                node.label,
                pattern: otherStoreHeaderPattern
            ) else {
                return nil
            }
            let count = captures.first.flatMap(Int.init) ?? 1
            guard count > 0 else {
                return nil
            }
            let endY = sectionHeaders.first { $0.y > node.y }?.y
                ?? Double.greatestFiniteMagnitude
            return (node, endY, count)
        }

        var rows: [PinduoduoPendingRow] = []
        var seen: Set<String> = []
        var coveredStores: Set<String> = []
        for markerNode in snapshot.nodes {
            guard let marker = pendingMarker(in: markerNode.label) else {
                continue
            }
            let nearby = snapshot.nodes.filter {
                abs($0.y - markerNode.y) <= 38
                    && $0.x >= 55
                    && $0.width >= 20
                    && !$0.label.isEmpty
            }
            let section = sectionFor(
                y: markerNode.y,
                headers: sectionHeaders
            )
            if section.contains("已回复") {
                continue
            }
            let normalizedMarker = marker.replacingOccurrences(
                of: #"\d+"#,
                with: "#",
                options: .regularExpression
            )
            let labels = nearby
                .sorted { $0.y < $1.y }
                .map(\.label)
                .filter { $0 != marker }
            let storeName = labels.first(where: {
                $0.count <= 20
                    && $0 != "店铺"
                    && !$0.contains("秒后超时")
            }) ?? "未知店铺"
            let preview = labels
                .filter { $0 != storeName }
                .max(by: { $0.count < $1.count }) ?? ""
            let identity = [
                "pdd",
                section,
                storeName,
                preview,
                normalizedMarker,
            ]
            .joined(separator: "|")
            guard seen.insert(identity).inserted else {
                continue
            }
            coveredStores.insert("\(section)|\(storeName)")
            rows.append(
                PinduoduoPendingRow(
                    section: section,
                    storeName: storeName,
                    preview: preview,
                    marker: marker,
                    identity: identity,
                    centerX: markerNode.x + markerNode.width / 2,
                    centerY: markerNode.y + markerNode.height / 2
                )
            )
        }

        for section in otherSections {
            let sectionNodes = snapshot.nodes.filter {
                $0.y > section.header.y && $0.y < section.endY
            }
            let stores = sectionNodes.filter {
                $0.kind == "StaticText"
                    && $0.x >= 70
                    && $0.x < 140
                    && $0.width >= 30
                    && $0.width <= 130
                    && $0.label.count <= 20
            }
            for store in stores {
                let storeKey = "\(section.header.label)|\(store.label)"
                guard !coveredStores.contains(storeKey) else {
                    continue
                }
                let rowNodes = sectionNodes.filter {
                    abs($0.y - store.y) <= 38
                }
                let preview = rowNodes
                    .filter { $0.label != store.label }
                    .max(by: { $0.label.count < $1.label.count })?
                    .label ?? ""
                let identity = [
                    "pdd",
                    section.header.label,
                    store.label,
                    preview,
                    "other-store",
                ]
                .joined(separator: "|")
                guard seen.insert(identity).inserted else {
                    continue
                }
                rows.append(
                    PinduoduoPendingRow(
                        section: section.header.label,
                        storeName: store.label,
                        preview: preview,
                        marker: "other-store-section",
                        identity: identity,
                        centerX: store.x + store.width / 2,
                        centerY: store.y + store.height / 2
                    )
                )
            }
        }
        var unique: [String: PinduoduoPendingRow] = [:]
        for row in rows {
            let key = row.storeName == "未知店铺"
                ? row.identity
                : "\(row.section)|\(row.storeName)"
            if let existing = unique[key],
               existing.marker != "other-store-section" {
                continue
            }
            unique[key] = row
        }
        return unique.values.sorted { $0.centerY < $1.centerY }
    }

    private static func isDirectChat(_ snapshot: AccessibilitySnapshot) -> Bool {
        snapshot.source.contains("NavigationBar")
            && snapshot.nodes.contains { $0.kind == "TextView" }
            && snapshot.source.contains("订单")
            && !snapshot.source.contains("PMChatContainerView")
    }

    private static func customerName(_ snapshot: AccessibilitySnapshot) -> String {
        guard let identifier = regexCaptures(
            snapshot.source,
            pattern: navigationIDPattern
        )?.first else {
            return "未知客户"
        }
        return identifier.replacingOccurrences(
            of: #"\(\d+\)$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func sectionFor(
        y: Double,
        headers: [AccessibilityNode]
    ) -> String {
        headers.last(where: { $0.y < y })?.label ?? ""
    }

    private static func regexCaptures(
        _ text: String,
        pattern: String
    ) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map {
                String(text[$0])
            } ?? ""
        }
    }

    private static func firstMatch(
        _ text: String,
        pattern: String
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let resultRange = Range(match.range, in: text)
        else {
            return nil
        }
        return String(text[resultRange])
    }

    private static func pendingMarker(in label: String) -> String? {
        if label.contains("已等待") {
            return firstMatch(
                label,
                pattern: #"已等待(?:\s*\d+\s*(?:秒|分钟))?"#
            ) ?? "已等待"
        }
        if label.contains("待回复") {
            return "待回复"
        }
        if label.contains("即将超时") {
            return "即将超时"
        }
        return firstMatch(
            label,
            pattern: #"(?:约\s*)?\d+\s*(?:秒|分钟)后超时"#
        )
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }
}

public enum PinduoduoDriverError: Error, Equatable {
    case notPendingList
    case stalePendingRow
    case notDirectChat
    case replyInputNotFound
    case typedReplyNotVerified
    case sendButtonNotFound
    case emptyReply
}

public enum PinduoduoSendReceipt: Equatable, Sendable {
    case sentVerified
    case sendUncertain(reason: String)
}

public actor PinduoduoDriver {
    public static let bundleID = "com.xunmeng.merchant"

    private let bridge: any AppUIBridge

    public init(bridge: any AppUIBridge) {
        self.bridge = bridge
    }

    public func inspect() async throws -> PinduoduoSurface {
        let snapshot = try await bridge.snapshot(bundleID: Self.bundleID)
        return PinduoduoPageParser.parse(snapshot)
    }

    public func open(_ row: PinduoduoPendingRow) async throws -> String {
        let snapshot = try await bridge.snapshot(bundleID: Self.bundleID)
        guard case let .pendingList(currentRows) =
            PinduoduoPageParser.parse(snapshot)
        else {
            throw PinduoduoDriverError.notPendingList
        }
        guard currentRows.contains(where: { $0.identity == row.identity }) else {
            throw PinduoduoDriverError.stalePendingRow
        }
        try await bridge.tap(x: row.centerX, y: row.centerY)
        let opened = try await bridge.snapshot(bundleID: Self.bundleID)
        guard case let .directChat(customer) =
            PinduoduoPageParser.parse(opened)
        else {
            throw PinduoduoDriverError.notDirectChat
        }
        return customer
    }

    public func prepareReply(_ reply: String) async throws {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PinduoduoDriverError.emptyReply
        }
        let snapshot = try await bridge.snapshot(bundleID: Self.bundleID)
        guard case .directChat = PinduoduoPageParser.parse(snapshot) else {
            throw PinduoduoDriverError.notDirectChat
        }
        guard let input = replyInput(in: snapshot) else {
            throw PinduoduoDriverError.replyInputNotFound
        }
        try await bridge.type(
            text: trimmed,
            x: input.centerX,
            y: input.centerY,
            clear: true
        )
        let typed = try await bridge.snapshot(bundleID: Self.bundleID)
        guard typed.nodes.contains(where: {
            $0.kind == "TextView" && $0.value == trimmed
        }) else {
            throw PinduoduoDriverError.typedReplyNotVerified
        }
    }

    public func sendPreparedReply(
        _ reply: String
    ) async throws -> PinduoduoSendReceipt {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = try await bridge.snapshot(bundleID: Self.bundleID)
        guard case .directChat = PinduoduoPageParser.parse(before) else {
            throw PinduoduoDriverError.notDirectChat
        }
        guard before.nodes.contains(where: {
            $0.kind == "TextView" && $0.value == trimmed
        }) else {
            throw PinduoduoDriverError.typedReplyNotVerified
        }
        guard let send = sendButton(in: before) else {
            throw PinduoduoDriverError.sendButtonNotFound
        }
        let beforeCount = messageOccurrences(of: trimmed, in: before)
        try await bridge.tap(x: send.centerX, y: send.centerY)
        let after = try await bridge.snapshot(bundleID: Self.bundleID)
        let afterCount = messageOccurrences(of: trimmed, in: after)
        let inputStillContainsReply = after.nodes.contains {
            $0.kind == "TextView" && $0.value == trimmed
        }
        if afterCount > beforeCount && !inputStillContainsReply {
            return .sentVerified
        }
        return .sendUncertain(
            reason: "reply was not uniquely verified as a sent merchant message"
        )
    }

    private func replyInput(
        in snapshot: AccessibilitySnapshot
    ) -> AccessibilityNode? {
        snapshot.nodes
            .filter {
                $0.kind == "TextView"
                    && $0.width >= 100
                    && $0.y >= 300
            }
            .max(by: { $0.y < $1.y })
    }

    private func sendButton(
        in snapshot: AccessibilitySnapshot
    ) -> AccessibilityNode? {
        snapshot.nodes
            .filter {
                $0.kind == "Button"
                    && $0.x >= 300
                    && $0.y >= 730
                    && $0.width >= 20
                    && $0.width <= 56
                    && $0.height >= 20
                    && $0.height <= 56
            }
            .max(by: { $0.x < $1.x })
    }

    private func messageOccurrences(
        of reply: String,
        in snapshot: AccessibilitySnapshot
    ) -> Int {
        snapshot.nodes.filter {
            ($0.kind == "Other" || $0.kind == "StaticText")
                && $0.label == reply
        }.count
    }
}
