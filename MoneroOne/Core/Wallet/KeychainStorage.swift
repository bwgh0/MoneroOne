import Foundation
import Security
import CryptoKit
import CommonCrypto

class KeychainStorage {
    // MARK: - Migration

    private static let migrationKey = "one.monero.keychain.migratedToAfterFirstUnlock"

    /// Migrate existing keychain items to use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    /// This fixes the issue where wallet data appears lost after device reboot or extended lock
    func migrateKeychainAccessibilityIfNeeded() {
        // Only run migration once
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey) else { return }

        // Migrate all network variants
        migrateKeychainItem(account: "one.monero.MoneroOne.mainnet.seed")
        migrateKeychainItem(account: "one.monero.MoneroOne.mainnet.pinhash")
        migrateKeychainItem(account: "one.monero.MoneroOne.mainnet.salt")
        migrateKeychainItem(account: "one.monero.MoneroOne.mainnet.pinlength")
        migrateKeychainItem(account: "one.monero.MoneroOne.testnet.seed")
        migrateKeychainItem(account: "one.monero.MoneroOne.testnet.pinhash")
        migrateKeychainItem(account: "one.monero.MoneroOne.testnet.salt")
        migrateKeychainItem(account: "one.monero.MoneroOne.testnet.pinlength")

        // Biometric PIN uses access control, handle separately
        migrateBiometricPinIfNeeded()

        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: Self.migrationKey)
    }

    private func migrateKeychainItem(account: String) {
        // Read existing data
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return // Item doesn't exist or can't be read
        }

        // Delete the old item
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Re-add with new accessibility
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func migrateBiometricPinIfNeeded() {
        // Check if biometric PIN exists (without triggering auth)
        let checkQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: biometricPinKey,
            kSecReturnData as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        let checkStatus = SecItemCopyMatching(checkQuery as CFDictionary, nil)

        // If it exists, we can't migrate it without user authentication
        // The new accessibility will be applied when the user re-enables biometrics
        // or on next save. For now, just skip biometric migration.
        if checkStatus == errSecSuccess || checkStatus == errSecInteractionNotAllowed {
            // Item exists - will be updated on next biometric setup
            return
        }
    }

    // MARK: - Network-Prefixed Keychain Keys
    // CRITICAL: Each network (mainnet/testnet) must have separate seed storage
    // to prevent users from backing up the wrong seed after switching networks

    private var isTestnet: Bool {
        UserDefaults.standard.bool(forKey: "isTestnet")
    }

    private var networkPrefix: String {
        isTestnet ? "testnet" : "mainnet"
    }

    private var seedKey: String {
        "one.monero.MoneroOne.\(networkPrefix).seed"
    }

    private var pinHashKey: String {
        "one.monero.MoneroOne.\(networkPrefix).pinhash"
    }

    private var saltKey: String {
        "one.monero.MoneroOne.\(networkPrefix).salt"
    }

    private var pinLengthKey: String {
        "one.monero.MoneroOne.\(networkPrefix).pinlength"
    }

    // Biometric PIN is shared across networks (same PIN unlocks both)
    private let biometricPinKey = "one.monero.MoneroOne.biometricpin"

    // MARK: - Rate Limiting (Keychain-backed)

    private let rateLimitService = "one.monero.MoneroOne.rateLimit"
    private let failedAttemptsAccount = "failedAttempts"
    private let lockoutUntilAccount = "lockoutUntil"
    private let maxAttempts = 5

    private var failedAttempts: Int {
        get { getRateLimitInt(failedAttemptsAccount) }
        set { setRateLimitValue(failedAttemptsAccount, value: "\(newValue)") }
    }

    private var lockoutUntil: TimeInterval {
        get { getRateLimitDouble(lockoutUntilAccount) }
        set { setRateLimitValue(lockoutUntilAccount, value: "\(newValue)") }
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

    /// One-time migration of rate limiting from UserDefaults to Keychain
    func migrateRateLimitIfNeeded() {
        let migrated = UserDefaults.standard.bool(forKey: "rateLimitMigratedToKeychain")
        guard !migrated else { return }

        let oldAttempts = UserDefaults.standard.integer(forKey: "pinFailedAttempts")
        let oldLockout = UserDefaults.standard.double(forKey: "pinLockoutUntil")
        if oldAttempts > 0 { failedAttempts = oldAttempts }
        if oldLockout > 0 { lockoutUntil = oldLockout }

        UserDefaults.standard.removeObject(forKey: "pinFailedAttempts")
        UserDefaults.standard.removeObject(forKey: "pinLockoutUntil")
        UserDefaults.standard.set(true, forKey: "rateLimitMigratedToKeychain")
    }

    private func setRateLimitValue(_ account: String, value: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: rateLimitService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let data = value.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: rateLimitService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func getRateLimitString(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: rateLimitService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func getRateLimitInt(_ account: String) -> Int {
        guard let str = getRateLimitString(account) else { return 0 }
        return Int(str) ?? 0
    }

    private func getRateLimitDouble(_ account: String) -> Double {
        guard let str = getRateLimitString(account) else { return 0 }
        return Double(str) ?? 0
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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

        // Migrate to current iterations if decrypted with legacy count
        if decryptWith(encryptedData, pin: pin, salt: salt, iterations: Self.currentIterations) == nil {
            // Decryption succeeded with legacy iterations — re-encrypt with current
            try? saveSeed(seed, pin: pin)
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

    // MARK: - PIN Length Storage

    func savePinLength(_ length: Int) {
        let data = Data("\(length)".utf8)

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: pinLengthKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: pinLengthKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func getPinLength() -> Int? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: pinLengthKey,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8),
              let length = Int(str) else {
            return nil
        }

        return length
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
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
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

    // MARK: - Wallet-ID-Scoped Methods

    /// Save seed encrypted with PIN for a specific wallet
    func saveSeed(_ seed: String, pin: String, walletId: UUID) throws {
        let prefix = "one.monero.MoneroOne.wallet.\(walletId.uuidString)"
        let salt = generateSalt()
        let pinHash = hashPin(pin, salt: salt)

        guard let encryptedSeed = encrypt(seed, with: pin, salt: salt) else {
            throw KeychainError.encryptionFailed
        }

        // Delete existing
        deleteSeed(walletId: walletId)

        // Save encrypted seed
        try saveKeychainItem(account: "\(prefix).seed", data: encryptedSeed)
        try saveKeychainItem(account: "\(prefix).pinhash", data: pinHash)
        try saveKeychainItem(account: "\(prefix).salt", data: salt)

        resetFailedAttempts()
    }

    /// Retrieve seed for a specific wallet
    func getSeed(pin: String, walletId: UUID) throws -> String? {
        if isLockedOut {
            throw KeychainError.lockedOut(remainingSeconds: lockoutRemainingSeconds)
        }

        let prefix = "one.monero.MoneroOne.wallet.\(walletId.uuidString)"

        // Verify PIN against this wallet's stored hash
        guard verifyPin(pin, pinHashAccount: "\(prefix).pinhash", saltAccount: "\(prefix).salt") else {
            recordFailedAttempt()
            return nil
        }

        resetFailedAttempts()

        guard let salt = getKeychainData(account: "\(prefix).salt") else { return nil }
        guard let encryptedData = getKeychainData(account: "\(prefix).seed") else { return nil }
        return decrypt(encryptedData, with: pin, salt: salt)
    }

    /// Delete seed for a specific wallet
    func deleteSeed(walletId: UUID) {
        let prefix = "one.monero.MoneroOne.wallet.\(walletId.uuidString)"
        for suffix in ["seed", "pinhash", "salt"] {
            deleteKeychainItem(account: "\(prefix).\(suffix)")
        }
    }

    /// Check if a wallet has a stored seed
    func hasSeed(walletId: UUID) -> Bool {
        let account = "one.monero.MoneroOne.wallet.\(walletId.uuidString).seed"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - View-only wallet storage

    private struct ViewOnlyKeys: Codable {
        let address: String
        let viewKey: String
    }

    /// Save an address + private view key pair for a view-only wallet.
    /// Shares the PIN hash / salt slots with the seed path so the unlock
    /// flow is identical regardless of wallet source.
    func saveViewOnly(address: String, viewKey: String, pin: String, walletId: UUID) throws {
        let prefix = "one.monero.MoneroOne.wallet.\(walletId.uuidString)"
        let salt = generateSalt()
        let pinHash = hashPin(pin, salt: salt)

        let payload = ViewOnlyKeys(address: address, viewKey: viewKey)
        guard
            let payloadData = try? JSONEncoder().encode(payload),
            let payloadString = String(data: payloadData, encoding: .utf8),
            let encrypted = encrypt(payloadString, with: pin, salt: salt)
        else {
            throw KeychainError.encryptionFailed
        }

        deleteViewOnly(walletId: walletId)
        deleteSeed(walletId: walletId) // ensure no stale seed shares these slots

        try saveKeychainItem(account: "\(prefix).viewonly", data: encrypted)
        try saveKeychainItem(account: "\(prefix).pinhash", data: pinHash)
        try saveKeychainItem(account: "\(prefix).salt", data: salt)

        resetFailedAttempts()
    }

    func getViewOnly(pin: String, walletId: UUID) throws -> (address: String, viewKey: String)? {
        if isLockedOut {
            throw KeychainError.lockedOut(remainingSeconds: lockoutRemainingSeconds)
        }

        let prefix = "one.monero.MoneroOne.wallet.\(walletId.uuidString)"

        guard verifyPin(pin, pinHashAccount: "\(prefix).pinhash", saltAccount: "\(prefix).salt") else {
            recordFailedAttempt()
            return nil
        }

        resetFailedAttempts()

        guard
            let salt = getKeychainData(account: "\(prefix).salt"),
            let encrypted = getKeychainData(account: "\(prefix).viewonly"),
            let decoded = decrypt(encrypted, with: pin, salt: salt),
            let data = decoded.data(using: .utf8),
            let payload = try? JSONDecoder().decode(ViewOnlyKeys.self, from: data)
        else {
            return nil
        }
        return (payload.address, payload.viewKey)
    }

    func deleteViewOnly(walletId: UUID) {
        let prefix = "one.monero.MoneroOne.wallet.\(walletId.uuidString)"
        deleteKeychainItem(account: "\(prefix).viewonly")
        // Leave pinhash/salt — shared with seed path; deleteWallet cleans those
    }

    func hasViewOnly(walletId: UUID) -> Bool {
        let account = "one.monero.MoneroOne.wallet.\(walletId.uuidString).viewonly"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Copy raw keychain data from one account to another (for migration)
    func copyKeychainData(fromAccount: String, toAccount: String) {
        guard let data = getKeychainData(account: fromAccount) else { return }
        deleteKeychainItem(account: toAccount)
        try? saveKeychainItem(account: toAccount, data: data)
    }

    // MARK: - Keychain Helpers

    private func saveKeychainItem(account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed
        }
    }

    private func getKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Verify PIN against a specific pinHash/salt account pair
    private func verifyPin(_ pin: String, pinHashAccount: String, saltAccount: String) -> Bool {
        guard let storedHash = getKeychainData(account: pinHashAccount) else { return false }

        if let salt = getKeychainData(account: saltAccount) {
            let inputHash = hashPin(pin, salt: salt)
            if storedHash == inputHash { return true }

            let legacyIterHash = deriveKey(from: pin, salt: salt, keyLength: 32, iterations: Self.legacyIterations)
            if storedHash == legacyIterHash { return true }
        }

        let legacyHash = hashPinLegacy(pin)
        return storedHash == legacyHash
    }

    /// Delete all keychain items (used by UI tests for clean state)
    func deleteAll() {
        for prefix in ["mainnet", "testnet"] {
            for suffix in ["seed", "pinhash", "salt", "pinlength"] {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "one.monero.MoneroOne.\(prefix).\(suffix)"
                ]
                SecItemDelete(query as CFDictionary)
            }
        }
        // Also delete all wallet-ID-scoped items
        deleteAllWalletKeychainItems()
        deleteBiometricPin()
        resetFailedAttempts()

        // Clear rate limiting Keychain entries
        let rateLimitQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: rateLimitService,
        ]
        SecItemDelete(rateLimitQuery as CFDictionary)
    }

    /// Delete all wallet-ID-scoped keychain items (matches prefix pattern)
    private func deleteAllWalletKeychainItems() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return }

        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
               account.hasPrefix("one.monero.MoneroOne.wallet.") {
                deleteKeychainItem(account: account)
            }
        }
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

        // Try with salt first (new format, current iterations)
        if let salt = getSalt() {
            let inputHash = hashPin(pin, salt: salt)
            if storedHash == inputHash {
                return true
            }

            // Fall back to old iteration count (migration from 100k → 600k)
            let legacyIterHash = deriveKey(from: pin, salt: salt, keyLength: 32, iterations: Self.legacyIterations)
            if storedHash == legacyIterHash {
                return true
            }
        }

        // Fall back to legacy hash without salt (very old wallets)
        let legacyHash = hashPinLegacy(pin)
        if storedHash == legacyHash {
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

    private static let currentIterations: UInt32 = 600_000
    private static let legacyIterations: UInt32 = 100_000

    private func hashPin(_ pin: String, salt: Data) -> Data {
        return deriveKey(from: pin, salt: salt, keyLength: 32)
    }

    private func deriveKey(from pin: String, salt: Data, keyLength: Int, iterations: UInt32 = currentIterations) -> Data {
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
                    iterations,
                    derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    keyLength
                )
            }
        }

        guard result == kCCSuccess else {
            fatalError("PBKDF2 key derivation failed with CCStatus \(result). This indicates a programming error in key derivation parameters.")
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
        // Try current iteration count first
        if let result = decryptWith(data, pin: pin, salt: salt, iterations: Self.currentIterations) {
            return result
        }
        // Fall back to legacy iteration count (migration)
        return decryptWith(data, pin: pin, salt: salt, iterations: Self.legacyIterations)
    }

    private func decryptWith(_ data: Data, pin: String, salt: Data, iterations: UInt32) -> String? {
        let keyData = deriveKey(from: pin, salt: salt, keyLength: 32, iterations: iterations)
        let key = SymmetricKey(data: keyData)

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
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
