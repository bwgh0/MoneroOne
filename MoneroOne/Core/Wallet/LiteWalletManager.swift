import Foundation
import Combine
import CryptoKit
import os.log

private let logger = Logger(subsystem: "one.monero.MoneroOne", category: "LiteWallet")

/// Manages lite mode wallet sync using Light Wallet Server
/// Provides fast sync by sharing view key with server for blockchain scanning
@MainActor
class LiteWalletManager: ObservableObject {
    // MARK: - Published State
    @Published var balance: Decimal = 0
    @Published var unlockedBalance: Decimal = 0
    @Published var syncState: SyncState = .idle
    @Published var transactions: [MoneroTransaction] = []
    @Published var serverHealth: ServerHealth = .unknown

    enum SyncState: Equatable {
        case idle
        case connecting
        case syncing(progress: Double, remaining: Int?)
        case synced
        case error(String)
    }

    enum ServerHealth: Equatable {
        case unknown
        case healthy
        case unhealthy(String)
    }

    // MARK: - Private
    private var client: LiteWalletServerClient?
    private var address: String = ""
    private var viewKey: String = ""
    private var isRunning = false
    private var pollTask: Task<Void, Never>?
    private let coinRate: Decimal = 1_000_000_000_000

    // MARK: - Configuration
    private let pollInterval: TimeInterval = 10 // seconds

    // MARK: - Initialization

    /// Start lite mode sync with the given credentials
    /// - Parameters:
    ///   - address: Wallet address
    ///   - viewKey: Secret view key
    ///   - isTestnet: Whether to use testnet
    ///   - startHeight: Optional height to start scanning from (for restored wallets).
    ///                  For new wallets, pass current chain height for instant sync.
    func start(address: String, viewKey: String, isTestnet: Bool, startHeight: UInt64? = nil) async {
        guard !isRunning else { return }

        logger.info("Starting lite mode - address: \(address.prefix(20))..., viewKey: \(viewKey.prefix(8))..., startHeight: \(startHeight?.description ?? "nil")")

        self.address = address
        self.viewKey = viewKey
        self.client = LiteWalletServerClient(isTestnet: isTestnet)
        self.isRunning = true

        syncState = .connecting

        // Check server health first
        await checkServerHealth()
        logger.info("Server health: \(String(describing: self.serverHealth))")

        guard case .healthy = serverHealth else {
            if case .unhealthy(let msg) = serverHealth {
                logger.error("Server unhealthy: \(msg)")
                syncState = .error("Server unavailable: \(msg)")
            }
            return
        }

        // Register wallet with server (required before fetching data)
        guard let client = client else {
            logger.error("No client available for registration")
            syncState = .error("Internal error: no client")
            return
        }

        do {
            logger.info("Calling register endpoint with startHeight: \(startHeight?.description ?? "nil")...")
            let result = try await client.register(address: address, viewKey: viewKey, startHeight: startHeight)
            logger.info("Registration success: \(result.message ?? "no message")")
        } catch {
            logger.error("Registration failed: \(error.localizedDescription)")
            syncState = .error("Registration failed: \(error.localizedDescription)")
            return
        }

        // Wait a moment for server to process registration
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Initial sync
        await fetchBalanceAndTransactions()

        // Start polling for updates
        startPolling()
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        syncState = .idle
    }

    func refresh() async {
        logger.info("refresh() called, current state: \(String(describing: self.syncState))")
        guard isRunning, client != nil else {
            logger.warning("refresh() skipped - isRunning: \(self.isRunning), hasClient: \(self.client != nil)")
            return
        }

        // Set connecting state to trigger Live Activity update
        // This shows "Syncing..." immediately while we check for new blocks
        if case .synced = syncState {
            logger.info("Transitioning from .synced to .connecting for refresh")
            syncState = .connecting
        }

        await fetchBalanceAndTransactions()
    }

    // MARK: - Server Health

    private func checkServerHealth() async {
        guard let client = client else {
            serverHealth = .unhealthy("No client")
            return
        }

        do {
            let health = try await client.healthCheck()
            if health.status == "healthy" && health.daemonSynced {
                serverHealth = .healthy
            } else if !health.daemonSynced {
                serverHealth = .unhealthy("Server syncing blockchain")
            } else {
                serverHealth = .unhealthy(health.status)
            }
        } catch {
            serverHealth = .unhealthy(error.localizedDescription)
        }
    }

    // MARK: - Sync Logic

    private func startPolling() {
        pollTask = Task { [weak self] in
            while let self = self, self.isRunning {
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))

                guard !Task.isCancelled else { break }

                await self.fetchBalanceAndTransactions()
            }
        }
    }

    private func fetchBalanceAndTransactions() async {
        guard let client = client, !address.isEmpty else { return }

        do {
            // First check sync status to get accurate progress
            let syncStatus = try await client.syncStatus(address: address)
            let percentComplete = syncStatus.percentComplete
            let remaining = syncStatus.chainHeight > syncStatus.scannedHeight
                ? Int(syncStatus.chainHeight - syncStatus.scannedHeight)
                : 0
            // Consider synced if within 1 block (we're always slightly behind the tip)
            let isSynced = percentComplete >= 99 || remaining <= 1

            if !isSynced {
                syncState = .syncing(progress: Double(percentComplete), remaining: remaining)
            }

            // Fetch balance
            let balanceResponse = try await client.getBalance(address: address, viewKey: viewKey)

            if let total = Decimal(string: balanceResponse.totalBalance),
               let unlocked = Decimal(string: balanceResponse.unlockedBalance) {
                self.balance = total / coinRate
                self.unlockedBalance = unlocked / coinRate
            }

            // Fetch transactions
            let txResponse = try await client.getTransactions(address: address, viewKey: viewKey)
            self.transactions = txResponse.transactions.map { mapTransaction($0) }

            // Set final state based on sync status
            if isSynced {
                syncState = .synced
            }

        } catch let error as LWSError {
            switch error {
            case .notFound:
                // Wallet not found - try to register
                do {
                    _ = try await client.register(address: address, viewKey: viewKey)
                    // Retry fetch after registration
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await fetchBalanceAndTransactions()
                } catch {
                    syncState = .error("Failed to register wallet")
                }
            default:
                syncState = .error(error.localizedDescription)
            }
        } catch is CancellationError {
            // Ignore cancellation - this happens during pull-to-refresh gestures
        } catch {
            syncState = .error(error.localizedDescription)
        }
    }

    private func mapTransaction(_ tx: LWSTransaction) -> MoneroTransaction {
        let amount: Decimal
        if let amountDecimal = Decimal(string: tx.amount) {
            amount = amountDecimal / coinRate
        } else {
            amount = 0
        }

        let fee: Decimal
        if let feeString = tx.fee, let feeDecimal = Decimal(string: feeString) {
            fee = feeDecimal / coinRate
        } else {
            fee = 0
        }

        let timestamp: Date
        if let ts = tx.timestamp {
            timestamp = Date(timeIntervalSince1970: Double(ts))
        } else {
            timestamp = Date()
        }

        // Use actual confirmations from server, default to 0 if not available
        let confirmations = tx.confirmations ?? 0

        // Status: pending (0 confs), confirmed (1-9 confs but locked), confirmed (10+ unlocked)
        let status: MoneroTransaction.TransactionStatus = confirmations > 0 ? .confirmed : .pending

        return MoneroTransaction(
            id: tx.txHash,
            type: tx.isIncoming ? .incoming : .outgoing,
            amount: amount,
            fee: fee,
            address: tx.address ?? "",
            timestamp: timestamp,
            confirmations: confirmations,
            status: status,
            memo: nil
        )
    }

    // MARK: - Send Transaction

    /// Send a pre-signed transaction through the LWS
    func sendTransaction(signedTxHex: String) async throws -> String {
        guard let client = client else {
            throw LWSError.invalidResponse
        }

        let response = try await client.sendTransaction(signedTxHex: signedTxHex)
        return response.txHash
    }
}

// MARK: - View Key Derivation

extension LiteWalletManager {
    /// Derive view key from seed using standard Monero key derivation
    /// Note: This is a simplified version - full implementation requires monero-crypto
    static func deriveViewKey(from seed: [String]) -> String? {
        // For now, return nil - the actual derivation happens in MoneroKit
        // We'll need to expose the view key from MoneroKit or derive it here
        // This is a placeholder for the integration
        return nil
    }
}
