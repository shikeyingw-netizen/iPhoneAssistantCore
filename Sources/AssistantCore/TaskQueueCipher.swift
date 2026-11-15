import CryptoKit
import Foundation

public protocol SensitivePayloadCipher: Sendable {
    func encrypt(_ clearText: Data) throws -> Data
    func decrypt(_ cipherText: Data) throws -> Data
}

public enum TaskQueueCipherError: Error {
    case invalidKey
    case invalidSealedData
}

public struct AESGCMTaskCipher: SensitivePayloadCipher {
    private let key: SymmetricKey

    public init(keyData: Data) throws {
        guard keyData.count == 32 else {
            throw TaskQueueCipherError.invalidKey
        }
        self.key = SymmetricKey(data: keyData)
    }

    public func encrypt(_ clearText: Data) throws -> Data {
        let sealed = try AES.GCM.seal(clearText, using: key)
        guard let combined = sealed.combined else {
            throw TaskQueueCipherError.invalidSealedData
        }
        return combined
    }

    public func decrypt(_ cipherText: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: cipherText)
        return try AES.GCM.open(box, using: key)
    }
}
