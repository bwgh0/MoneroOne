import Foundation
import Security
import CryptoKit
import CommonCrypto

class KeychainStorage {
    private let seedKey = "one.monero.MoneroOne.seed"
    private let pinHashKey = "one.monero.MoneroOne.pinhash"
    private let biometricPinKey = "one.monero.MoneroOne.biometricpin"
    private let saltKey = "one.monero.MoneroOne.salt"

    // MARK: - Rate Limiting

    private let failedAttemptsKey = "pinFailedAttempts"
    private let lockoutUntilKey = "pinLockoutUntil"
    private let maxAttempts = 5

    private var failedAttempts: Int {
        get { UserDefaults.standard.integer(forKey: failedAttemptsKey) }
        set { UserDefaults.standard.set(newValue, forKey: failedAttemptsKey) }
    }

    private var lockoutUntil: TimeInterval {
        get { UserDefaults.standard.double(forKey: lockoutUntilKey) }
        set { UserDefaults.standard.set(newValue, forKey: lockoutUntilKey) }
    }

    /// Check if PIN entry is currently locked out
    var isLockedOut: Bool {
        Date().timeIntervalSince1970 < lockoutUntil
    }

    /// Remaining lockout time in seconds (0 if not locked)
    var lockoutRemainingSeconds: Int {
        let remaining = lockoutUntil - Date().timeIntervalSince1970
        return remaining > 0 ? Int(remaining) : 0
    }

    /// Reset failed attempts (call after successful PIN entry)
    func resetFailedAttempts() {
        failedAttempts = 0
        lockoutUntil = 0
    }

    /// Record a failed PIN attempt and apply lockout if needed
    private func recordFailedAttempt() {
        failedAttempts += 1

        if failedAttempts >= maxAttempts {
            // Exponential backoff: 1min, 2min, 4min, 8min, 16min...
            let lockoutMinutes = pow(2.0, Double(failedAttempts - maxAttempts))
            let maxLockoutMinutes = 60.0 // Cap at 1 hour
            let actualLockoutMinutes = min(lockoutMinutes, maxLockoutMinutes)
            lockoutUntil = Date().timeIntervalSince1970 + (actualLockoutMinutes * 60)
        }
    }

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
        // Generate random salt for this wallet
        let salt = generateSalt()

        // Hash the PIN with salt for verification
        let pinHash = hashPin(pin, salt: salt)

        // Encrypt seed with PIN-derived key using AES-GCM
        guard let encryptedSeed = encrypt(seed, with: pin, salt: salt) else {
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

        // Save salt
        let saltQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: saltKey,
            kSecValueData as String: salt,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        status = SecItemAdd(saltQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed
        }

        // Reset failed attempts on successful save
        resetFailedAttempts()
    }

    func getSeed(pin: String) throws -> String? {
        // Check lockout first
        if isLockedOut {
            throw KeychainError.lockedOut(remainingSeconds: lockoutRemainingSeconds)
        }

        // Verify PIN first
        guard verifyPin(pin) else {
            recordFailedAttempt()
            return nil
        }

        // Reset failed attempts on successful verification
        resetFailedAttempts()

        // Get salt
        guard let salt = getSalt() else {
            // Legacy wallet without salt - try old decryption
            return try getLegacySeed(pin: pin)
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
              let seed = decrypt(encryptedData, with: pin, salt: salt) else {
            return nil
        }

        return seed
    }

    /// Attempt to retrieve seed using legacy XOR encryption (for migration)
    private func getLegacySeed(pin: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: seedKey,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let encryptedData = result as? Data,
              let seed = decryptLegacy(encryptedData, with: pin) else {
            return nil
        }

        // Migration: re-encrypt with new secure method
        try? saveSeed(seed, pin: pin)

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

        let saltQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: saltKey
        ]
        SecItemDelete(saltQuery as CFDictionary)
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
        // Security comes from keychain access control (Face ID required), not encryption
        guard let pinData = pin.data(using: .utf8) else {
            throw KeychainError.saveFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: biometricPinKey,
            kSecValueData as String: pinData,
            kSecAttrAccessControl as String: accessControl
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed
        }
    }

    /// Retrieve PIN using biometric authentication (Face ID/Touch ID prompt)
    /// Returns nil if biometrics fail or PIN not stored
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

    /// Verify PIN matches biometrically stored hash
    func verifyBiometricPin(_ pin: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: biometricPinKey,
            kSecReturnData as String: true,
            kSecUseOperationPrompt as String: "Unlock your Monero wallet"
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let storedHash = result as? Data else {
            return false
        }

        // Check if legacy plaintext PIN
        if let plainPin = String(data: storedHash, encoding: .utf8),
           plainPin.count <= 6, plainPin.allSatisfy({ $0.isNumber }) {
            return pin == plainPin
        }

        // Compare hashes
        let inputHash = hashPinForBiometrics(pin)
        return storedHash == inputHash
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

        // Try with salt first (new format)
        if let salt = getSalt() {
            let inputHash = hashPin(pin, salt: salt)
            if storedHash == inputHash {
                return true
            }
        }

        // Fall back to legacy hash (for migration)
        let legacyHash = hashPinLegacy(pin)
        if storedHash == legacyHash {
            // Migration: if we have a seed, re-save with new encryption
            return true
        }

        return false
    }

    // MARK: - Salt Management

    private func generateSalt() -> Data {
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, baseAddress)
        }
        return salt
    }

    private func getSalt() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: saltKey,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let salt = result as? Data else {
            return nil
        }

        return salt
    }

    // MARK: - Modern Encryption (AES-GCM with PBKDF2)

    private func hashPin(_ pin: String, salt: Data) -> Data {
        // Use PBKDF2 with 100,000 iterations
        return deriveKey(from: pin, salt: salt, keyLength: 32)
    }

    // Fixed salt for biometric PIN (constant, so force unwrap is safe)
    private static let biometricSalt = Data("one.monero.biometric.salt".utf8)

    private func hashPinForBiometrics(_ pin: String) -> Data {
        // Use a fixed salt for biometric PIN hashing
        // This is less secure than random salt but we don't have
        // access to the wallet salt when storing biometric PIN
        return deriveKey(from: pin, salt: Self.biometricSalt, keyLength: 32)
    }

    private func deriveKey(from pin: String, salt: Data, keyLength: Int) -> Data {
        var derivedKey = Data(count: keyLength)

        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pin,
                    pin.utf8.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    100_000, // iterations
                    derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    keyLength
                )
            }
        }

        guard result == kCCSuccess else {
            // Fall back to simple hash if PBKDF2 fails
            return Data(SHA256.hash(data: Data(pin.utf8)))
        }

        return derivedKey
    }

    private func encrypt(_ string: String, with pin: String, salt: Data) -> Data? {
        guard let plaintext = string.data(using: .utf8) else { return nil }

        // Derive encryption key using PBKDF2
        let keyData = deriveKey(from: pin, salt: salt, keyLength: 32)
        let key = SymmetricKey(data: keyData)

        do {
            // Encrypt using AES-GCM
            let sealedBox = try AES.GCM.seal(plaintext, using: key)

            // Return nonce + ciphertext + tag combined
            guard let combined = sealedBox.combined else { return nil }
            return combined
        } catch {
            return nil
        }
    }

    private func decrypt(_ data: Data, with pin: String, salt: Data) -> String? {
        // Derive decryption key using PBKDF2
        let keyData = deriveKey(from: pin, salt: salt, keyLength: 32)
        let key = SymmetricKey(data: keyData)

        do {
            // Reconstruct sealed box from combined data
            let sealedBox = try AES.GCM.SealedBox(combined: data)

            // Decrypt
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            return String(data: decrypted, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Legacy Encryption (for migration from old wallets)

    private func hashPinLegacy(_ pin: String) -> Data {
        let data = Data(pin.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash)
    }

    private func decryptLegacy(_ data: Data, with pin: String) -> String? {
        let key = deriveKeyLegacy(from: pin, length: data.count)

        var decrypted = [UInt8](repeating: 0, count: data.count)
        for i in 0..<data.count {
            decrypted[i] = data[i] ^ key[i % key.count]
        }
        return String(data: Data(decrypted), encoding: .utf8)
    }

    private func deriveKeyLegacy(from pin: String, length: Int) -> [UInt8] {
        let pinData = Data(pin.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        pinData.withUnsafeBytes { buffer in
            CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &key)
        }
        return key
    }
}

enum KeychainError: LocalizedError {
    case saveFailed
    case encryptionFailed
    case notFound
    case lockedOut(remainingSeconds: Int)

    var errorDescription: String? {
        switch self {
        case .saveFailed: return "Failed to save to keychain"
        case .encryptionFailed: return "Encryption failed"
        case .notFound: return "Item not found in keychain"
        case .lockedOut(let seconds):
            let minutes = seconds / 60
            let secs = seconds % 60
            if minutes > 0 {
                return "Too many failed attempts. Try again in \(minutes)m \(secs)s"
            } else {
                return "Too many failed attempts. Try again in \(secs)s"
            }
        }
    }
}
