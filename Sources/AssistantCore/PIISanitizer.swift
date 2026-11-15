import Foundation

public enum PIISanitizer {
    private static let patterns: [(String, String)] = [
        (#"(?<!\d)(1[3-9]\d)\d{4}(\d{4})(?!\d)"#, "$1****$2"),
        (#"(?<!\d)(\d{6})\d{8}(\d{3}[0-9Xx])(?!\d)"#, "$1********$2"),
        (
            #"(?:[\p{Han}]{2,}(?:省|自治区|市|区|县|镇|乡|街道))[\p{Han}A-Za-z0-9\-号栋单元室座路街巷弄]{5,}"#,
            "[地址已脱敏]"
        ),
    ]

    public static func sanitize(_ text: String) -> String {
        var result = text
        let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: replacement
            )
        }
        _ = fullRange
        return result
    }
}
