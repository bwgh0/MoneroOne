import CryptoKit
import Foundation
import Security

/// Manages THP pairing credentials in the Keychain.
///
/// On first connection, the Trezor requires pairing via a 6-digit code displayed
/// on the device screen. After pairing, the host's static key is stored in the
/// Keychain so subsequent connections can skip pairing.
enum THPPairing {

    /// Keychain service identifier for THP credentials
    private static let keychainService = "one.monero.thp.pairing"

    // MARK: - Host Static Key

    /// Load or create the persistent host static key.
    /// This key is used across all Noise_XX handshakes so the Trezor can recognize
    /// this host after initial pairing.
    static func loadOrCreateHostStaticKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let existingKey = loadHostStaticKey() {
            TrezorLog.log("[Pairing] Loaded existing host static key")
            return existingKey
        }

        let newKey = Curve25519.KeyAgreement.PrivateKey()
        storeHostStaticKey(newKey)
        TrezorLog.log("[Pairing] Created and stored new host static key")
        return newKey
    }

    /// Store host static key in Keychain
    private static func storeHostStaticKey(_ key: Curve25519.KeyAgreement.PrivateKey) {
        let keyData = key.rawRepresentation

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "host_static_key",
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Delete any existing key first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            TrezorLog.log("[Pairing] WARNING: Failed to store host key in Keychain: %d", status)
        }
    }

    /// Load host static key from Keychain
    private static func loadHostStaticKey() -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "host_static_key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let keyData = result as? Data else {
            return nil
        }

        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
    }

    // MARK: - Device Pairing Credentials

    /// Store a pairing credential for a specific Trezor device.
    /// The credential tag proves to the device that we've been paired before.
    static func storeCredential(deviceId: String, credential: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "device_\(deviceId)",
            kSecValueData as String: credential,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            TrezorLog.log("[Pairing] Stored credential for device %@", deviceId)
        } else {
            TrezorLog.log("[Pairing] WARNING: Failed to store credential: %d", status)
        }
    }

    /// Load a pairing credential for a specific Trezor device.
    static func loadCredential(deviceId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "device_\(deviceId)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        TrezorLog.log("[Pairing] Loaded credential for device %@", deviceId)
        return data
    }

    /// Check if we have a stored credential for a device (i.e., previously paired)
    static func isPaired(deviceId: String) -> Bool {
        return loadCredential(deviceId: deviceId) != nil
    }

    /// Remove pairing credential for a device
    static func removeCredential(deviceId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "device_\(deviceId)"
        ]

        SecItemDelete(query as CFDictionary)
        TrezorLog.log("[Pairing] Removed credential for device %@", deviceId)
    }
}
