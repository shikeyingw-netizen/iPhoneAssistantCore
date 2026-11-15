import CryptoKit
import Foundation

public enum StableIdentifier {
    public static func hexDigest(_ parts: String...) -> String {
        let canonical = parts.joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func messageKey(
        platform: CommercePlatform,
        storeName: String,
        customerName: String,
        customerText: String,
        notificationKey: String
    ) -> String {
        String(
            hexDigest(
                platform.rawValue,
                storeName,
                customerName,
                customerText,
                notificationKey
            ).prefix(24)
        )
    }

    public static func logisticsFingerprint(
        orderID: String,
        action: LogisticsAction,
        trackingNumber: String
    ) -> String {
        String(
            hexDigest(orderID, action.rawValue, trackingNumber).prefix(20)
        )
    }
}
