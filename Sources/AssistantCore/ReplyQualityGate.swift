import Foundation

public enum ReplyViolation: String, Codable, CaseIterable, Sendable {
    case empty
    case tooLong
    case containsAISelfReference
    case containsPII
    case unauthorizedHighRiskPromise
}

public struct ReplyQualityResult: Equatable, Sendable {
    public let normalizedReply: String
    public let violations: [ReplyViolation]
    public let manualReviewRequired: Bool

    public init(
        normalizedReply: String,
        violations: [ReplyViolation],
        manualReviewRequired: Bool
    ) {
        self.normalizedReply = normalizedReply
        self.violations = violations
        self.manualReviewRequired = manualReviewRequired
    }

    public var isSafe: Bool {
        violations.isEmpty
    }

    public var canAutoSend: Bool {
        isSafe && !manualReviewRequired
    }
}

public enum ReplyQualityGate {
    public static func validate(
        _ rawReply: String,
        assessment: RiskAssessment,
        maximumLength: Int = 240
    ) -> ReplyQualityResult {
        let normalized = rawReply
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var violations: [ReplyViolation] = []
        if normalized.isEmpty {
            violations.append(.empty)
        }
        if normalized.count > maximumLength {
            violations.append(.tooLong)
        }
        if MerchantPolicy.containsAny(
            normalized,
            ["作为AI", "作为 AI", "人工智能模型", "语言模型"]
        ) {
            violations.append(.containsAISelfReference)
        }
        if PIISanitizer.sanitize(normalized) != normalized {
            violations.append(.containsPII)
        }
        if assessment.requiresHumanReview,
           MerchantPolicy.containsAny(
               normalized,
               ["已经退款", "马上退款", "保证改", "一定改", "已经改好", "给你赔", "直接补发"]
           ) {
            violations.append(.unauthorizedHighRiskPromise)
        }

        return ReplyQualityResult(
            normalizedReply: normalized,
            violations: violations,
            manualReviewRequired: assessment.requiresHumanReview
        )
    }
}
