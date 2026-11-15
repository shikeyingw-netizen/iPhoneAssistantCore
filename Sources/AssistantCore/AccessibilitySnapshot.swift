import Foundation

public struct AccessibilityNode: Equatable, Sendable {
    public let kind: String
    public let details: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        kind: String,
        details: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.kind = kind
        self.details = details
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var label: String {
        Self.capture(#"(?:^|, )label: '(.*?)'(?=, |$)"#, in: details)
    }

    public var value: String {
        Self.capture(#"(?:^|, )value: '(.*?)'(?=, |$)"#, in: details)
    }

    public var identifier: String {
        Self.capture(#"id: '(.*?)'"#, in: details)
    }

    public var centerX: Double {
        x + width / 2
    }

    public var centerY: Double {
        y + height / 2
    }

    private static func capture(_ pattern: String, in text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return ""
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return ""
        }
        return String(text[captureRange])
            .replacingOccurrences(of: "\u{0003}", with: "")
            .replacingOccurrences(of: "\u{0004}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct AccessibilitySnapshot: Equatable, Sendable {
    public let source: String
    public let nodes: [AccessibilityNode]
    public let capturedAt: Date

    public init(source: String, nodes: [AccessibilityNode], capturedAt: Date) {
        self.source = source
        self.nodes = nodes
        self.capturedAt = capturedAt
    }

    public func nodes(kind: String) -> [AccessibilityNode] {
        nodes.filter { $0.kind == kind }
    }

    public func firstNode(label: String) -> AccessibilityNode? {
        nodes.first { $0.label == label }
    }
}

public enum AccessibilityTreeParser {
    private static let nodeExpression = try? NSRegularExpression(
        pattern: #"^( *)([A-Za-z]+[0-9]*)(?:, (.*))?, \{\{(-?\d+), (-?\d+)\}, \{(\d+), (\d+)\}\}$"#,
        options: []
    )

    public static func parse(_ source: String, capturedAt: Date = Date()) -> AccessibilitySnapshot {
        var nodes: [AccessibilityNode] = []
        guard let nodeExpression else {
            return AccessibilitySnapshot(source: source, nodes: [], capturedAt: capturedAt)
        }
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = nodeExpression.firstMatch(in: text, range: range),
                  let kindRange = Range(match.range(at: 2), in: text),
                  let xRange = Range(match.range(at: 4), in: text),
                  let yRange = Range(match.range(at: 5), in: text),
                  let widthRange = Range(match.range(at: 6), in: text),
                  let heightRange = Range(match.range(at: 7), in: text),
                  let x = Double(text[xRange]),
                  let y = Double(text[yRange]),
                  let width = Double(text[widthRange]),
                  let height = Double(text[heightRange])
            else {
                continue
            }
            let details: String
            if let detailsRange = Range(match.range(at: 3), in: text) {
                details = String(text[detailsRange])
            } else {
                details = ""
            }
            nodes.append(
                AccessibilityNode(
                    kind: String(text[kindRange]),
                    details: details,
                    x: x,
                    y: y,
                    width: width,
                    height: height
                )
            )
        }
        return AccessibilitySnapshot(source: source, nodes: nodes, capturedAt: capturedAt)
    }
}
