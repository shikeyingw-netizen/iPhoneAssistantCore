import CryptoKit
import Foundation

public struct ICTRLHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol ICTRLHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ICTRLHTTPResponse
}

public struct URLSessionICTRLTransport: ICTRLHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> ICTRLHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ICTRLRPCError.invalidHTTPResponse
        }
        return ICTRLHTTPResponse(
            statusCode: httpResponse.statusCode,
            data: data
        )
    }
}

public enum ICTRLRPCError: Error, Equatable {
    case invalidConfiguration
    case invalidHTTPResponse
    case invalidEnvelope
    case responseAuthenticationFailed
    case invalidJSON
    case missingResult
    case rpc(status: Int, message: String)
}

public struct ICTRLRPCConfiguration: Sendable {
    public let baseURL: URL
    public let key: Data
    public let token: Data

    public init(baseURL: URL, key: Data, token: Data) throws {
        guard key.count == 32, token.count == 4 else {
            throw ICTRLRPCError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.key = key
        self.token = token
    }
}

public protocol ICTRLRPCInvoking: Sendable {
    func call(
        method: String,
        params: ICTRLJSONValue
    ) async throws -> ICTRLJSONValue
}

struct ICTRLEncryptedRequest: Codable, Equatable {
    let v: Int
    let tok: String
    let ts: UInt64
    let nonce: String
    let ct: String
    let tag: String
}

struct ICTRLEncryptedResponse: Codable, Equatable {
    let ct: String
    let tag: String
}

enum ICTRLCrypto {
    static let requestLabel = Data("ictrl-v1|enc-req".utf8)
    static let responseLabel = Data("ictrl-v1|enc-resp".utf8)
    static let macLabel = Data("ictrl-v1|mac".utf8)

    static func hmac(key: Data, data: Data) -> Data {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: data,
            using: SymmetricKey(data: key)
        )
        return Data(authenticationCode)
    }

    static func xor(key: Data, nonce: Data, data: Data) -> Data {
        var output = Data(count: data.count)
        var counter: UInt32 = 0
        var offset = 0
        while offset < data.count {
            var block = Data()
            block.append(nonce)
            block.append(bigEndian(counter))
            let stream = hmac(key: key, data: block)
            let count = min(stream.count, data.count - offset)
            for index in 0..<count {
                output[offset + index] = data[offset + index] ^ stream[index]
            }
            offset += count
            counter &+= 1
        }
        return output
    }

    static func bigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    static func bigEndian(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map {
            UInt8((value >> UInt64($0 * 8)) & 0xff)
        })
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(hex value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else {
            return nil
        }
        var output = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(
                String(value[index..<next]),
                radix: 16
            ) else {
                return nil
            }
            output.append(byte)
            index = next
        }
        return output
    }

    static func randomNonce() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }
}

public actor ICTRLRPCClient: ICTRLRPCInvoking {
    private let configuration: ICTRLRPCConfiguration
    private let transport: any ICTRLHTTPTransport
    private let clock: @Sendable () -> Date
    private var timeOffset: TimeInterval = 0
    private var nextID = 1

    public init(
        configuration: ICTRLRPCConfiguration,
        transport: any ICTRLHTTPTransport = URLSessionICTRLTransport(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.clock = clock
    }

    public func call(
        method: String,
        params: ICTRLJSONValue = .object([:])
    ) async throws -> ICTRLJSONValue {
        try await performCall(method: method, params: params, allowTimeRetry: true)
    }

    private func performCall(
        method: String,
        params: ICTRLJSONValue,
        allowTimeRetry: Bool
    ) async throws -> ICTRLJSONValue {
        let rpcID = nextID
        nextID += 1
        let body = ICTRLJSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
            "id": .number(Double(rpcID)),
        ])
        let bodyData = try JSONEncoder().encode(body)
        let nonce = ICTRLCrypto.randomNonce()
        let timestamp = UInt64(
            max(0, floor(clock().timeIntervalSince1970 + timeOffset))
        )
        let requestKey = ICTRLCrypto.hmac(
            key: configuration.key,
            data: ICTRLCrypto.requestLabel + nonce
        )
        let cipherText = ICTRLCrypto.xor(
            key: requestKey,
            nonce: nonce,
            data: bodyData
        )
        let macKey = ICTRLCrypto.hmac(
            key: configuration.key,
            data: ICTRLCrypto.macLabel + nonce
        )
        let signed = Data("v1".utf8)
            + configuration.token
            + ICTRLCrypto.bigEndian(timestamp)
            + nonce
            + cipherText
        let tag = ICTRLCrypto.hmac(key: macKey, data: signed)
        let envelope = ICTRLEncryptedRequest(
            v: 1,
            tok: ICTRLCrypto.hex(configuration.token),
            ts: timestamp,
            nonce: ICTRLCrypto.hex(nonce),
            ct: cipherText.base64EncodedString(),
            tag: ICTRLCrypto.hex(tag)
        )

        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent("rpc")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(envelope)

        let response = try await transport.send(request)
        if response.statusCode != 200 {
            let errorValue = try? JSONDecoder().decode(
                ICTRLJSONValue.self,
                from: response.data
            )
            if allowTimeRetry,
               let serverTimestamp = errorValue?.firstNumber(forKey: "server_ts") {
                timeOffset = serverTimestamp - clock().timeIntervalSince1970
                return try await performCall(
                    method: method,
                    params: params,
                    allowTimeRetry: false
                )
            }
            let message = String(
                data: response.data,
                encoding: .utf8
            ) ?? "unknown error"
            throw ICTRLRPCError.rpc(
                status: response.statusCode,
                message: message
            )
        }

        let encryptedResponse: ICTRLEncryptedResponse
        do {
            encryptedResponse = try JSONDecoder().decode(
                ICTRLEncryptedResponse.self,
                from: response.data
            )
        } catch {
            throw ICTRLRPCError.invalidEnvelope
        }
        guard let responseCipherText = Data(
            base64Encoded: encryptedResponse.ct
        ), let responseTag = ICTRLCrypto.data(
            hex: encryptedResponse.tag
        ) else {
            throw ICTRLRPCError.invalidEnvelope
        }
        let expectedTag = ICTRLCrypto.hmac(
            key: macKey,
            data: Data("resp".utf8) + nonce + responseCipherText
        )
        guard expectedTag == responseTag else {
            throw ICTRLRPCError.responseAuthenticationFailed
        }
        let responseKey = ICTRLCrypto.hmac(
            key: configuration.key,
            data: ICTRLCrypto.responseLabel + nonce
        )
        let clearText = ICTRLCrypto.xor(
            key: responseKey,
            nonce: nonce,
            data: responseCipherText
        )
        let decoded: ICTRLJSONValue
        do {
            decoded = try JSONDecoder().decode(
                ICTRLJSONValue.self,
                from: clearText
            )
        } catch {
            throw ICTRLRPCError.invalidJSON
        }
        if decoded["error"] != nil {
            throw ICTRLRPCError.rpc(
                status: 200,
                message: String(data: clearText, encoding: .utf8) ?? "RPC error"
            )
        }
        guard let result = decoded["result"] else {
            throw ICTRLRPCError.missingResult
        }
        return result
    }
}
