import Foundation

public enum ICTRLJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ICTRLJSONValue])
    case object([String: ICTRLJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ICTRLJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ICTRLJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public subscript(key: String) -> ICTRLJSONValue? {
        guard case let .object(value) = self else {
            return nil
        }
        return value[key]
    }

    public var objectValue: [String: ICTRLJSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    public var numberValue: Double? {
        guard case let .number(value) = self else {
            return nil
        }
        return value
    }

    func firstNumber(forKey key: String) -> Double? {
        switch self {
        case let .number(value):
            return value
        case let .array(values):
            return values.lazy.compactMap { $0.firstNumber(forKey: key) }.first
        case let .object(values):
            if let direct = values[key]?.numberValue {
                return direct
            }
            return values.values.lazy.compactMap {
                $0.firstNumber(forKey: key)
            }.first
        case .bool, .null, .string:
            return nil
        }
    }
}
