import Foundation

public struct OrderSnapshot: Codable, Equatable, Sendable {
    public let orderID: String
    public let buyerID: String
    public let status: OrderStatus
    public let carrierLabel: String
    public let trackingNumber: String
    public let refundPending: Bool
    public let refundHistoryCount: Int

    public init(
        orderID: String,
        buyerID: String,
        status: OrderStatus,
        carrierLabel: String,
        trackingNumber: String,
        refundPending: Bool = false,
        refundHistoryCount: Int = 0
    ) {
        self.orderID = orderID
        self.buyerID = buyerID
        self.status = status
        self.carrierLabel = carrierLabel
        self.trackingNumber = trackingNumber
        self.refundPending = refundPending
        self.refundHistoryCount = refundHistoryCount
    }
}

public struct NewRecipientAddress: Codable, Equatable, Sendable {
    public let recipientName: String
    public let phone: String
    public let province: String
    public let city: String
    public let district: String
    public let streetAddress: String

    public init(
        recipientName: String,
        phone: String,
        province: String,
        city: String,
        district: String,
        streetAddress: String
    ) {
        self.recipientName = recipientName
        self.phone = phone
        self.province = province
        self.city = city
        self.district = district
        self.streetAddress = streetAddress
    }
}

public struct LogisticsDecision: Equatable, Sendable {
    public let allowed: Bool
    public let action: LogisticsAction
    public let reason: String
    public let missingFields: [String]
    public let groupName: String
    public let courierMessage: String

    public init(
        allowed: Bool,
        action: LogisticsAction,
        reason: String = "",
        missingFields: [String] = [],
        groupName: String = "",
        courierMessage: String = ""
    ) {
        self.allowed = allowed
        self.action = action
        self.reason = reason
        self.missingFields = missingFields
        self.groupName = groupName
        self.courierMessage = courierMessage
    }
}

public struct LogisticsPolicy: Sendable {
    public let groups: [Courier: String]

    public init(groups: [Courier: String]) {
        self.groups = groups
    }

    public func intercept(_ order: OrderSnapshot) -> LogisticsDecision {
        if order.refundHistoryCount > 1 {
            return LogisticsDecision(
                allowed: false,
                action: .intercept,
                reason: "检测到重复退款申请，转人工核实"
            )
        }
        if order.refundPending {
            return LogisticsDecision(
                allowed: false,
                action: .intercept,
                reason: "该订单已有退款流程，避免重复拦截"
            )
        }
        if let error = validate(order) {
            return LogisticsDecision(
                allowed: false,
                action: .intercept,
                reason: error
            )
        }
        guard let courier = normalizeCarrier(order),
              let groupName = groups[courier],
              !groupName.isEmpty
        else {
            return LogisticsDecision(
                allowed: false,
                action: .intercept,
                reason: "快递群名称尚未配置"
            )
        }
        return LogisticsDecision(
            allowed: true,
            action: .intercept,
            groupName: groupName,
            courierMessage: "\(order.trackingNumber) 拦截"
        )
    }

    public func changeAddress(
        _ order: OrderSnapshot,
        address: NewRecipientAddress
    ) -> LogisticsDecision {
        if let error = validate(order) {
            return LogisticsDecision(
                allowed: false,
                action: .addressChange,
                reason: error
            )
        }
        let missing = missingAddressFields(address)
        if !missing.isEmpty {
            return LogisticsDecision(
                allowed: false,
                action: .addressChange,
                reason: "地址信息不完整",
                missingFields: missing
            )
        }
        guard let courier = normalizeCarrier(order),
              let groupName = groups[courier],
              !groupName.isEmpty
        else {
            return LogisticsDecision(
                allowed: false,
                action: .addressChange,
                reason: "快递群名称尚未配置"
            )
        }

        let addressText = address.province
            + address.city
            + address.district
            + address.streetAddress
        let courierMessage = order.trackingNumber
            + " 改地址 + "
            + address.recipientName
            + " "
            + address.phone
            + " "
            + addressText
        return LogisticsDecision(
            allowed: true,
            action: .addressChange,
            groupName: groupName,
            courierMessage: courierMessage
        )
    }

    public func fingerprint(
        order: OrderSnapshot,
        action: LogisticsAction
    ) -> String {
        StableIdentifier.logisticsFingerprint(
            orderID: order.orderID,
            action: action,
            trackingNumber: order.trackingNumber
        )
    }

    public func normalizeCarrier(_ order: OrderSnapshot) -> Courier? {
        let label = order.carrierLabel.lowercased()
        if label.contains("申通") || label.contains("sto") {
            return .sto
        }
        if label.contains("极兔")
            || label.contains("j&t")
            || label.contains("jnt")
            || label.contains("jet")
        {
            return .jnt
        }
        if order.trackingNumber.uppercased().hasPrefix("JT") {
            return .jnt
        }
        return nil
    }

    private func validate(_ order: OrderSnapshot) -> String? {
        if order.status == .signed {
            return "订单已签收，不能发送拦截或改地址请求"
        }
        if order.status != .shipped {
            return "订单尚未发货或状态不明确"
        }
        if order.trackingNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "缺少快递单号"
        }
        if normalizeCarrier(order) == nil {
            return "无法可靠识别快递公司"
        }
        return nil
    }

    private func missingAddressFields(_ address: NewRecipientAddress) -> [String] {
        var missing: [String] = []
        let checks: [(String, String)] = [
            ("收件人姓名", address.recipientName),
            ("联系电话", address.phone),
            ("省份", address.province),
            ("城市", address.city),
            ("区县", address.district),
            ("详细地址", address.streetAddress),
        ]
        for (label, value) in checks
        where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(label)
        }
        let phone = address.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !missing.contains("联系电话"),
           phone.range(of: #"^1[3-9]\d{9}$"#, options: .regularExpression) == nil {
            missing.append("联系电话")
        }
        if !missing.contains("详细地址"),
           address.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 {
            missing.append("详细地址")
        }
        return missing
    }
}
