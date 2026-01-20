import XCTest
@testable import MoneroOne
import MoneroKit

/// Real LWS Integration Tests
/// Tests the wallet2 C++ code path through MoneroKit against our LWS server.
@MainActor
final class LWSTransactionTests: XCTestCase {

    // MARK: - Test Configuration

    /// LWS server URL
    static let lwsURL = URL(string: "http://REDACTED_IP:3000")!

    /// Test mnemonic (testnet wallet with funds)
    static let testMnemonic = "pond industry exit mirror hobby pole stand mutual rubber vendor asthma fold rain behind indicate above voice fix glare toddler motion describe caution budget".split(separator: " ").map(String.init)

    /// Expected address for this mnemonic
    static let expectedAddress = "9uACtnkMLeJP3iRsijiHNSCgsXKWqFif7g3B22Es1vtTUan9iFC1Uz3BEpjkNjQJcVc2a1vcRYPrNij6AJx45vNm5TGKeR7"

    /// Burn address for test transactions
    static let burnAddress = "78P9z1Ss8xDyBpg2tshTT8Z6DGgG3KJqAsACU8mbj7Y4BTh92cPDL7AHLYi8b8M6bftfBUEJDh1K7eMxxSJFbBxU3r5Y6a5"

    var wallet: MoneroOne.MoneroWallet!

    override func setUp() async throws {
        wallet = MoneroOne.MoneroWallet()
    }

    override func tearDown() async throws {
        wallet = nil
    }

    // MARK: - Light Wallet Sync Tests

    /// Test that we can connect to LWS and sync the wallet using wallet2 C++
    func testLightWalletSync() async throws {
        // Create light wallet - this uses the actual wallet2 C++ code
        print("Creating light wallet with URL: \(Self.lwsURL)")
        print("Mnemonic word count: \(Self.testMnemonic.count)")

        do {
            try wallet.createLightWallet(
                seed: Self.testMnemonic,
                lwsURL: Self.lwsURL,
                restoreHeight: 0,
                networkType: .testnet
            )
            print("Light wallet created successfully")
        } catch {
            XCTFail("Failed to create light wallet: \(error)")
            return
        }

        // Start syncing
        print("Starting wallet sync...")
        wallet.start()

        // Wait for sync (max 120 seconds for light wallet)
        let timeout: TimeInterval = 120
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let state = wallet.syncState

            switch state {
            case .synced:
                print("Synced!")
            case .syncing(let progress, let remaining):
                print("Syncing: \(progress)% remaining: \(remaining ?? 0)")
            case .error(let msg):
                print("ERROR STATE REACHED: \(msg)")
                print("Full syncState: \(state)")
                XCTFail("Sync error: \(msg)")
                return
            case .connecting:
                print("Connecting...")
            case .idle:
                print("Idle...")
            }

            if case .synced = state {
                break
            }

            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        // Verify we synced
        guard case .synced = wallet.syncState else {
            XCTFail("Failed to sync within \(timeout) seconds. State: \(wallet.syncState)")
            return
        }

        // Verify address matches
        print("Wallet address: \(wallet.address)")
        XCTAssertEqual(wallet.address, Self.expectedAddress, "Address should match expected")

        // Verify we have a balance
        print("Balance: \(wallet.balance) XMR")
        print("Unlocked balance: \(wallet.unlockedBalance) XMR")

        XCTAssertGreaterThan(wallet.balance, 0, "Wallet should have balance")
    }

    /// Test fee estimation - this exercises the get_unspent_outs parsing in wallet2
    func testFeeEstimation() async throws {
        // Create and sync light wallet
        try wallet.createLightWallet(
            seed: Self.testMnemonic,
            lwsURL: Self.lwsURL,
            restoreHeight: 0,
            networkType: .testnet
        )

        wallet.start()

        // Wait for sync
        try await waitForSync(timeout: 120)

        // Verify we have unlocked balance
        guard wallet.unlockedBalance > 0 else {
            print("No unlocked balance - skipping fee estimation test")
            return
        }

        // Try to estimate fee for a small transaction
        // This will call get_unspent_outs and parse the response
        // If the server returns wrong field names (per_kb_fee vs per_byte_fee), this will fail
        do {
            let amount: Decimal = 0.001 // 0.001 XMR
            let fee = try await wallet.estimateFee(to: Self.burnAddress, amount: amount)

            print("Estimated fee for \(amount) XMR: \(fee) XMR")
            XCTAssertGreaterThan(fee, 0, "Fee should be greater than 0")
        } catch {
            // This is the key test - if this fails with parsing errors,
            // the server response format is wrong
            XCTFail("Fee estimation failed: \(error)")
        }
    }

    /// Test actual transaction creation and broadcast
    /// WARNING: This will actually send funds!
    func testTransactionSend() async throws {
        // Create and sync light wallet
        try wallet.createLightWallet(
            seed: Self.testMnemonic,
            lwsURL: Self.lwsURL,
            restoreHeight: 0,
            networkType: .testnet
        )

        wallet.start()

        // Wait for sync
        try await waitForSync(timeout: 120)

        // Verify we have enough unlocked balance
        let requiredBalance: Decimal = 0.002 // Need 0.001 + fee
        guard wallet.unlockedBalance >= requiredBalance else {
            print("Skipping send test - need at least \(requiredBalance) XMR unlocked balance")
            print("Current unlocked balance: \(wallet.unlockedBalance) XMR")
            return
        }

        // Try to send a small transaction
        do {
            let amount: Decimal = 0.001 // 0.001 XMR
            let txId = try await wallet.send(to: Self.burnAddress, amount: amount)

            print("Transaction sent! TX ID: \(txId)")
            XCTAssertFalse(txId.isEmpty, "Transaction ID should not be empty")
        } catch {
            XCTFail("Transaction send failed: \(error)")
        }
    }

    // MARK: - Helper Methods

    private func waitForSync(timeout: TimeInterval) async throws {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if case .synced = wallet.syncState {
                return
            }

            if case .error(let msg) = wallet.syncState {
                throw NSError(domain: "LWSTransactionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sync error: \(msg)"])
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw NSError(domain: "LWSTransactionTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sync timeout after \(timeout) seconds"])
    }
}
