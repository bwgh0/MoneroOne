import Foundation
import Security

class KeychainStorage {
    private let seedKey = "one.monero.MoneroOne.seed"
    private let pinHashKey = "one.monero.MoneroOne.pinhash"
    private let biometricPinKey = "one.monero.MoneroOne.biometricpin"

    // MARK: - Seed Storage

    func hasSeed() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: seedKey,
            kSecReturnData as String: false
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func saveSeed(_ seed: String, pin: String) throws {
        // Hash the PIN for verification
        let pinHash = hashPin(pin)

        // Encrypt seed with PIN-derived key
        guard let encryptedSeed = encrypt(seed, with: pin) else {
            throw KeychainError.encryptionFailed
        }

        // Delete existing if present
        deleteSeed()

        // Save encrypted seed
        let seedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: seedKey,
            kSecValueData as String: encryptedSeed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = SecItemAdd(seedQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed
        }

        // Save PIN hash
        let pinQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: pinHashKey,
            kSecValueData as String: pinHash,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        status = SecItemAdd(pinQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed
        }
    }

    func getSeed(pin: String) throws -> String? {
        // Verify PIN first
        guard verifyPin(pin) else {
            return nil
        }

        // Retrieve encrypted seed
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: seedKey,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let encryptedData = result as? Data,
              let seed = decrypt(encryptedData, with: pin) else {
            return nil
        }

        return seed
    }

    func deleteSeed() {
        let seedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: seedKey
        ]
        SecItemDelete(seedQuery as CFDictionary)

        let pinQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: pinHashKey
        ]
        SecItemDelete(pinQuery as CFDictionary)
    }

    // MARK: - Biometric PIN Storage

    /// Save PIN with biometric protection for Face ID/Touch ID unlock
    func savePinForBiometrics(_ pin: String) throws {
        // Delete existing biometric PIN if present
        deleteBiometricPin()

        // Create access control requiring biometric authentication
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else {
            throw KeychainError.saveFailed
        }

        // Store PIN with biometric protection
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: biometricPinKey,
            kSecValueData as String: Data(pin.utf8),
            kSecAttrAccessControl as String: accessControl
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed
        }
    }

    /// Retrieve PIN using biometric authentication (Face ID/Touch ID prompt)
    func getPinWithBiometrics() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: biometricPinKey,
            kSecReturnData as String: true,
            kSecUseOperationPrompt as String: "Unlock your Monero wallet"
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let pinData = result as? Data,
              let pin = String(data: pinData, encoding: .utf8) else {
            return nil
        }

        return pin
    }

    /// Check if biometric PIN is stored
    func hasBiometricPin() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: biometricPinKey,
            kSecReturnData as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed means it exists but needs biometrics
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Delete biometric PIN
    func deleteBiometricPin() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: biometricPinKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - PIN Verification

    private func verifyPin(_ pin: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: pinHashKey,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let storedHash = result as? Data else {
            return false
        }

        let inputHash = hashPin(pin)
        return storedHash == inputHash
    }

    // MARK: - Encryption Helpers

    private func hashPin(_ pin: String) -> Data {
        // Simple SHA256 hash - in production use PBKDF2 with salt
        let data = Data(pin.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash)
    }

    private func encrypt(_ string: String, with pin: String) -> Data? {
        // Simple XOR encryption with PIN-derived key
        // In production, use AES-GCM with PBKDF2-derived key
        guard let data = string.data(using: .utf8) else { return nil }
        let key = deriveKey(from: pin, length: data.count)

        var encrypted = [UInt8](repeating: 0, count: data.count)
        for i in 0..<data.count {
            encrypted[i] = data[i] ^ key[i % key.count]
        }
        return Data(encrypted)
    }

    private func decrypt(_ data: Data, with pin: String) -> String? {
        let key = deriveKey(from: pin, length: data.count)

        var decrypted = [UInt8](repeating: 0, count: data.count)
        for i in 0..<data.count {
            decrypted[i] = data[i] ^ key[i % key.count]
        }
        return String(data: Data(decrypted), encoding: .utf8)
    }

    private func deriveKey(from pin: String, length: Int) -> [UInt8] {
        let pinData = Data(pin.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        pinData.withUnsafeBytes { buffer in
            CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &key)
        }
        return key
    }
}

// CommonCrypto bridge
import CommonCrypto

enum KeychainError: LocalizedError {
    case saveFailed
    case encryptionFailed
    case notFound

    var errorDescription: String? {
        switch self {
        case .saveFailed: return "Failed to save to keychain"
        case .encryptionFailed: return "Encryption failed"
        case .notFound: return "Item not found in keychain"
        }
    }
}
