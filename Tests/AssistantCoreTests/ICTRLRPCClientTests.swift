import Foundation
import XCTest
@testable import AssistantCore

final class ICTRLRPCClientTests: XCTestCase {
    func testEncryptedRequestAndResponseRoundTrip() async throws {
        let key = Data(repeating: 0x5a, count: 32)
        let token = Data([0x11, 0x22, 0x33, 0x44])
        let transport = EncryptedStubTransport(
            key: key,
            token: token,
            expectedMethod: "device_info",
            result: .object([
                "device": .string("iPhone 13"),
                "bundle_id": .string("com.apple.springboard"),
            ])
        )
        let configuration = try ICTRLRPCConfiguration(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8200")),
            key: key,
            token: token
        )
        let client = ICTRLRPCClient(
            configuration: configuration,
            transport: transport,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let result = try await client.call(method: "device_info")

        XCTAssertEqual(result["device"]?.stringValue, "iPhone 13")
        let captured = await transport.capturedMethod()
        XCTAssertEqual(captured, "device_info")
    }

    func testResponseAuthenticationFailureIsRejected() async throws {
        let key = Data(repeating: 0x61, count: 32)
        let token = Data([0xaa, 0xbb, 0xcc, 0xdd])
        let transport = EncryptedStubTransport(
            key: key,
            token: token,
            expectedMethod: "page_source",
            result: .object([:]),
            corruptResponseTag: true
        )
        let configuration = try ICTRLRPCConfiguration(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8200")),
            key: key,
            token: token
        )
        let client = ICTRLRPCClient(
            configuration: configuration,
            transport: transport
        )

        do {
            _ = try await client.call(method: "page_source")
            XCTFail("tampered response must be rejected")
        } catch {
            XCTAssertEqual(
                error as? ICTRLRPCError,
                .responseAuthenticationFailed
            )
        }
    }

    func testConfigurationRejectsWrongKeyOrTokenLength() throws {
        XCTAssertThrowsError(
            try ICTRLRPCConfiguration(
                baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8200")),
                key: Data(repeating: 1, count: 31),
                token: Data(repeating: 2, count: 4)
            )
        )
    }
}

private enum ICTRLStubError: Error {
    case malformedRequest
    case wrongMethod
    case authenticationFailed
}

private actor EncryptedStubTransport: ICTRLHTTPTransport {
    private let key: Data
    private let token: Data
    private let expectedMethod: String
    private let result: ICTRLJSONValue
    private let corruptResponseTag: Bool
    private var method: String?
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    init(
        key: Data,
        token: Data,
        expectedMethod: String,
        result: ICTRLJSONValue,
        corruptResponseTag: Bool = false
    ) {
        self.key = key
        self.token = token
        self.expectedMethod = expectedMethod
        self.result = result
        self.corruptResponseTag = corruptResponseTag
    }

    func capturedMethod() -> String? {
        method
    }

    func send(_ request: URLRequest) async throws -> ICTRLHTTPResponse {
        guard let body = request.httpBody,
              let envelope = try? JSONDecoder().decode(
                ICTRLEncryptedRequest.self,
                from: body
              ),
              let nonce = ICTRLCrypto.data(hex: envelope.nonce),
              let requestTag = ICTRLCrypto.data(hex: envelope.tag),
              let requestCipherText = Data(base64Encoded: envelope.ct)
        else {
            throw ICTRLStubError.malformedRequest
        }

        let macKey = ICTRLCrypto.hmac(
            key: key,
            data: ICTRLCrypto.macLabel + nonce
        )
        let signed = Data("v1".utf8)
            + token
            + ICTRLCrypto.bigEndian(envelope.ts)
            + nonce
            + requestCipherText
        let expectedRequestTag = ICTRLCrypto.hmac(
            key: macKey,
            data: signed
        )
        guard expectedRequestTag == requestTag else {
            throw ICTRLStubError.authenticationFailed
        }

        let requestKey = ICTRLCrypto.hmac(
            key: key,
            data: ICTRLCrypto.requestLabel + nonce
        )
        let clearRequest = ICTRLCrypto.xor(
            key: requestKey,
            nonce: nonce,
            data: requestCipherText
        )
        let requestJSON = try JSONDecoder().decode(
            ICTRLJSONValue.self,
            from: clearRequest
        )
        guard let actualMethod = requestJSON["method"]?.stringValue,
              actualMethod == expectedMethod
        else {
            throw ICTRLStubError.wrongMethod
        }
        method = actualMethod

        let responseJSON = ICTRLJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": requestJSON["id"] ?? .number(1),
            "result": result,
        ])
        let clearResponse = try JSONEncoder().encode(responseJSON)
        let responseKey = ICTRLCrypto.hmac(
            key: key,
            data: ICTRLCrypto.responseLabel + nonce
        )
        let responseCipherText = ICTRLCrypto.xor(
            key: responseKey,
            nonce: nonce,
            data: clearResponse
        )
        let expectedResponseTag = ICTRLCrypto.hmac(
            key: macKey,
            data: Data("resp".utf8) + nonce + responseCipherText
        )
        let responseTag: Data
        if corruptResponseTag {
            responseTag = Data(repeating: 0, count: expectedResponseTag.count)
        } else {
            responseTag = expectedResponseTag
        }
        let response = ICTRLEncryptedResponse(
            ct: responseCipherText.base64EncodedString(),
            tag: ICTRLCrypto.hex(responseTag)
        )
        return ICTRLHTTPResponse(
            statusCode: 200,
            data: try JSONEncoder().encode(response)
        )
    }
}
