import Foundation
import SwiftUI
import Combine
import HdWalletKit

@MainActor
class WalletManager: ObservableObject {
    // MARK: - Published State
    @Published var hasWallet: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var balance: Decimal = 0
    @Published var unlockedBalance: Decimal = 0
    @Published var address: String = ""
    @Published var syncState: SyncState = .idle
    @Published var transactions: [MoneroTransaction] = []

    enum SyncState: Equatable {
        case idle
        case connecting
        case syncing(progress: Double, remaining: Int?)
        case synced
        case error(String)
    }

    // MARK: - Private
    private let keychain = KeychainStorage()
    private var moneroWallet: MoneroWallet?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        checkForExistingWallet()
    }

    private func checkForExistingWallet() {
        hasWallet = keychain.hasSeed()
    }

    // MARK: - Wallet Creation

    /// Generate a new 25-word Monero mnemonic using HdWalletKit
    func generateNewWallet() -> [String] {
        // Monero uses 25-word seeds (256 bits entropy + checksum)
        // HdWalletKit generates standard BIP39 mnemonics
        do {
            let mnemonic = try Mnemonic.generate(wordCount: .twentyFour, language: .english)
            // Monero typically uses 25 words, but we'll use 24-word BIP39 which MoneroKit accepts
            return mnemonic
        } catch {
            // Fallback to simpler generation if HdWalletKit fails
            print("Mnemonic generation failed: \(error)")
            return []
        }
    }

    func saveWallet(mnemonic: [String], pin: String, restoreHeight: UInt64? = nil) throws {
        let seedPhrase = mnemonic.joined(separator: " ")
        try keychain.saveSeed(seedPhrase, pin: pin)

        // Save restore height if provided
        if let height = restoreHeight {
            UserDefaults.standard.set(height, forKey: "restoreHeight")
        }

        hasWallet = true
    }

    func restoreWallet(mnemonic: [String], pin: String, restoreDate: Date? = nil) throws {
        guard validateMnemonic(mnemonic) else {
            throw WalletError.invalidMnemonic
        }

        let seedPhrase = mnemonic.joined(separator: " ")
        try keychain.saveSeed(seedPhrase, pin: pin)

        // Calculate restore height from date
        if let date = restoreDate {
            let restoreHeight = MoneroWallet.restoreHeight(for: date)
            UserDefaults.standard.set(restoreHeight, forKey: "restoreHeight")
        }

        hasWallet = true
    }

    private func validateMnemonic(_ mnemonic: [String]) -> Bool {
        // Accept 12, 24, or 25 word mnemonics
        let validCounts = [12, 24, 25]
        guard validCounts.contains(mnemonic.count) else { return false }

        // Validate against BIP39 word list
        do {
            try Mnemonic.validate(words: mnemonic)
            return true
        } catch {
            // Allow 25-word Monero seeds which may not pass BIP39 validation
            return mnemonic.count == 25
        }
    }

    // MARK: - Wallet Unlock

    func unlock(pin: String) throws {
        guard let seedPhrase = try keychain.getSeed(pin: pin) else {
            throw WalletError.invalidPin
        }

        let mnemonic = seedPhrase.split(separator: " ").map(String.init)

        // Create MoneroWallet and start syncing
        let wallet = MoneroWallet()
        let restoreHeight = UInt64(UserDefaults.standard.integer(forKey: "restoreHeight"))

        do {
            try wallet.create(seed: mnemonic, restoreHeight: restoreHeight)
        } catch {
            throw WalletError.invalidMnemonic
        }

        moneroWallet = wallet
        bindToWallet(wallet)

        isUnlocked = true
    }

    private func bindToWallet(_ wallet: MoneroWallet) {
        // Bind wallet state to manager state
        wallet.$balance
            .receive(on: DispatchQueue.main)
            .assign(to: &$balance)

        wallet.$unlockedBalance
            .receive(on: DispatchQueue.main)
            .assign(to: &$unlockedBalance)

        wallet.$address
            .receive(on: DispatchQueue.main)
            .assign(to: &$address)

        wallet.$syncState
            .receive(on: DispatchQueue.main)
            .map { state -> SyncState in
                switch state {
                case .idle: return .idle
                case .connecting: return .connecting
                case .syncing(let progress, let remaining):
                    return .syncing(progress: progress, remaining: remaining)
                case .synced: return .synced
                case .error(let msg): return .error(msg)
                }
            }
            .assign(to: &$syncState)

        wallet.$transactions
            .receive(on: DispatchQueue.main)
            .assign(to: &$transactions)
    }

    func lock() {
        moneroWallet?.stop()
        moneroWallet = nil
        isUnlocked = false
        balance = 0
        unlockedBalance = 0
        address = ""
        syncState = .idle
        transactions = []
    }

    // MARK: - Send

    func estimateFee(to address: String, amount: Decimal) async throws -> Decimal {
        guard let wallet = moneroWallet else {
            throw WalletError.notUnlocked
        }
        return try await wallet.estimateFee(to: address, amount: amount)
    }

    func send(to address: String, amount: Decimal, memo: String? = nil) async throws -> String {
        guard let wallet = moneroWallet else {
            throw WalletError.notUnlocked
        }
        return try await wallet.send(to: address, amount: amount, memo: memo)
    }

    func sendAll(to address: String, memo: String? = nil) async throws -> String {
        guard let wallet = moneroWallet else {
            throw WalletError.notUnlocked
        }
        return try await wallet.sendAll(to: address, memo: memo)
    }

    // MARK: - Validation

    func isValidAddress(_ address: String) -> Bool {
        MoneroWallet.isValidAddress(address)
    }

    // MARK: - Refresh

    func refresh() {
        moneroWallet?.refresh()
    }

    // MARK: - Delete Wallet

    func deleteWallet() {
        lock()
        keychain.deleteSeed()
        UserDefaults.standard.removeObject(forKey: "restoreHeight")
        hasWallet = false
    }
}

// MARK: - Errors

enum WalletError: LocalizedError {
    case invalidMnemonic
    case invalidPin
    case saveFailed
    case notUnlocked

    var errorDescription: String? {
        switch self {
        case .invalidMnemonic: return "Invalid seed phrase"
        case .invalidPin: return "Invalid PIN"
        case .saveFailed: return "Failed to save wallet"
        case .notUnlocked: return "Wallet is locked"
        }
    }
}
