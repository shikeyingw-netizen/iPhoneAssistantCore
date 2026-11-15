import Foundation

public enum MerchantPolicy {
    public static let shippingCutoff = "当天16:30前付款当天发货，16:30后次日发货"
    public static let deliveryEstimate = "河南洛阳发货，省内约2天，省外3-5天，新疆西藏约5-7天"
    public static let trialPolicy = "可试吃，到货七天内不吃不满意包退"
    public static let productScope = "主营鹩哥、八哥鸟粮及宠物用品，不卖活体鸟"
    public static let formulaRule = "A/B型配料基本一样但比例不同，价格高的营养比例更高，B型肉比例更多"

    public static let systemMarkers = [
        "直播小二",
        "商家运营小二",
        "淘宝商家运营",
        "阿里认证",
        "公益宝贝",
        "官方通知",
        "店铺预警",
        "订单通知",
        "站内信",
        "平台活动",
        "招商",
        "流量扶持",
        "双11巅峰价",
        "问大家",
        "客服机器人",
        "消费者对商品不满意",
    ]

    public static func assess(_ rawText: String) -> RiskAssessment {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return RiskAssessment(
                category: .emptyMessage,
                requiresHumanReview: true,
                safeHoldingReply: nil,
                reasons: ["消息为空，无法判断客户意图"]
            )
        }

        if containsAny(text, systemMarkers) {
            return RiskAssessment(
                category: .platformNotice,
                requiresHumanReview: false,
                safeHoldingReply: nil,
                reasons: ["平台通知或营销消息，不属于客户咨询"]
            )
        }

        if containsAny(text, ["改地址", "修改地址", "地址填错", "换地址", "换收货地址"]) {
            return RiskAssessment(
                category: .addressChange,
                requiresHumanReview: true,
                safeHoldingReply: "亲，可以协助尝试修改，请把新收件人姓名、电话和完整地址（省市区+详细地址）发给我；能否改成功要以快递确认为准哦。",
                reasons: ["客户要求修改收货地址"]
            )
        }

        if containsAny(text, ["退款", "退货", "仅退款", "退钱"]) {
            return RiskAssessment(
                category: .refund,
                requiresHumanReview: true,
                safeHoldingReply: "亲，收到您的退款问题了，我先为您核实订单和物流状态，确认后马上回复您～",
                reasons: ["涉及退款或退货"]
            )
        }

        if containsAny(text, ["赔偿", "赔付", "补发", "少发", "漏发", "错发", "空包", "少件"]) {
            return RiskAssessment(
                category: .compensation,
                requiresHumanReview: true,
                safeHoldingReply: "亲，收到您的问题了，这边先为您记录并尽快核实，请稍等一下～",
                reasons: ["涉及补发、赔偿或订单差异"]
            )
        }

        if containsAny(text, ["投诉", "差评", "起诉", "法律", "律师", "工商", "12315", "报警"]) {
            return RiskAssessment(
                category: .complaintOrLegal,
                requiresHumanReview: true,
                safeHoldingReply: "亲，收到您的情况了，我这边先为您详细记录并尽快核实，请稍等一下～",
                reasons: ["涉及投诉、差评或法律风险"]
            )
        }

        if containsAny(text, ["改价", "便宜点", "优惠", "打折", "返现"]) {
            return RiskAssessment(
                category: .pricingChange,
                requiresHumanReview: true,
                safeHoldingReply: "亲，价格和优惠这边需要为您核实一下，请稍等～",
                reasons: ["涉及价格或优惠承诺"]
            )
        }

        if containsAny(text, ["假货", "变质", "发霉", "过敏", "吃死", "死亡", "中毒", "有问题"]) {
            return RiskAssessment(
                category: .productSafety,
                requiresHumanReview: true,
                safeHoldingReply: "亲，收到您反馈的情况了，这边先为您记录并尽快核实，请稍等一下～",
                reasons: ["涉及商品安全或质量纠纷"]
            )
        }

        if containsAny(text, ["拦截", "拒收", "没收到", "查不到物流", "丢件", "物流异常", "未签收"]) {
            return RiskAssessment(
                category: .orderInterception,
                requiresHumanReview: true,
                safeHoldingReply: "亲，我这边马上为您核实订单和物流状态，请稍等一下～",
                reasons: ["涉及物流拦截或物流异常"]
            )
        }

        return RiskAssessment(
            category: .normal,
            requiresHumanReview: false,
            safeHoldingReply: nil,
            reasons: []
        )
    }

    public static func deterministicReply(for rawText: String) -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("客服自动回复测试") {
            return "客服测试成功"
        }
        if containsAny(text, ["活体", "卖鸟", "有鸟卖", "鹩哥卖吗", "八哥卖吗"]) {
            return "亲，我们店铺主营鹩哥、八哥鸟粮及宠物用品，暂时没有活体鸟出售哦。"
        }
        if containsAny(text, ["A型", "B型", "A款", "B款", "哪个好", "什么区别"]) {
            return "亲，A/B型配料基本一样，主要是比例不同；价格高的营养比例更高，B型的肉比例更多一些。"
        }
        if containsAny(text, ["试吃", "不吃", "包退", "七天"]) {
            return "亲，可以试吃，到货七天内不吃不满意包退哦。"
        }
        if containsAny(text, ["多久到", "几天到", "运输多久", "到货时间"]) {
            return "亲，河南洛阳发货，省内约2天，省外一般3-5天，新疆西藏约5-7天。"
        }
        if containsAny(text, ["什么时候发", "今天发", "多久发", "发货时间", "几点发"]) {
            return "亲，当天16:30前付款当天发货，16:30后付款次日发货哦。"
        }
        return nil
    }

    public static func response(for rawText: String) -> (RiskAssessment, String?) {
        let assessment = assess(rawText)
        if let holding = assessment.safeHoldingReply {
            return (assessment, holding)
        }
        guard assessment.shouldAutoReply else {
            return (assessment, nil)
        }
        return (assessment, deterministicReply(for: rawText))
    }

    public static func containsAny(_ text: String, _ markers: [String]) -> Bool {
        markers.contains(where: { marker in text.contains(marker) })
    }
}

public enum DeepSeekPromptBuilder {
    public static let systemRules = """
    你是拼多多和淘宝店铺的在线客服。店铺主营鹩哥、八哥鸟粮及宠物用品，不卖活体鸟。
    只能根据以下已知规则回答，禁止编造成分、库存、活动、物流承诺和平台规则：
    - \(MerchantPolicy.shippingCutoff)
    - \(MerchantPolicy.deliveryEstimate)
    - \(MerchantPolicy.trialPolicy)
    - \(MerchantPolicy.productScope)
    - \(MerchantPolicy.formulaRule)
    退款、退货、补发、赔偿、改价、投诉、地址修改和质量纠纷不得自行承诺。
    回答应简短、礼貌、口语化，一般30到90个汉字，只输出可直接发送的客服回复。
    """

    public static func prompt(for context: ConversationContext) -> String {
        let history = context.messages.suffix(14).map { message in
            let speaker: String
            switch message.side {
            case .customer:
                speaker = "客户"
            case .merchant:
                speaker = "店铺"
            case .system:
                speaker = "系统"
            }
            return "\(speaker): \(PIISanitizer.sanitize(message.text))"
        }.joined(separator: "\n")

        return """
        \(systemRules)

        平台：\(context.platform.displayName)
        店铺：\(PIISanitizer.sanitize(context.storeName))
        客户：\(PIISanitizer.sanitize(context.customerName))
        最近对话：
        \(String(history.suffix(2_400)))

        请直接给出客服回复，不要解释规则，不要添加引号或前缀。
        """
    }
}
