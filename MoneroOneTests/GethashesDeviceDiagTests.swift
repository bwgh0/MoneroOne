import CMonero
import XCTest

/// DIAGNOSTIC — not part of the regular suite (needs network + ~2 min).
/// Run on a physical device to exercise the DEVICE slice of the wallet2
/// library against the production node:
///
///   xcodebuild test -only-testing:MoneroOneTests/GethashesDeviceDiagTests
///
/// Purpose: the Trezor FULL-cache session fails with wallet2's
/// "failed to get hashes" on device, while the identical fast-refresh path
/// (old restore height → /gethashes.bin walk) works from monero-wallet-cli
/// v0.18.4.6 on macOS against the same node. This test runs that exact path
/// through the iOS-patched library with a throwaway software wallet, so a
/// failure here indicts the library build, not the Trezor wallet's cache.
final class GethashesDeviceDiagTests: XCTestCase {

    func testFastRefreshFromOldHeightAgainstProductionNode() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GethashesDiag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Full wallet2/epee logging to stderr — this is a diagnostic, the
        // usual logger-race concern is acceptable for a single wallet.
        MONERO_WalletManagerFactory_setLogLevel(2)

        let wm = MONERO_WalletManagerFactory_getWalletManager()
        XCTAssertNotNil(wm)

        // Throwaway deterministic wallet (the bip39 test vector's spend key)
        let spendKeyHex = "4fe2e8fa6ad56846a4b70b5cf85a8a5ff310d8eb5daaf5b11af9591d79fc0a02"
        let restoreHeight: UInt64 = 3_600_000

        let wallet = MONERO_WalletManager_createDeterministicWalletFromSpendKey(
            wm, tempDir.appendingPathComponent("diag").path, "pw", "English",
            0, restoreHeight, spendKeyHex, 1
        )
        XCTAssertNotNil(wallet)
        XCTAssertEqual(MONERO_Wallet_status(wallet), 0, "wallet creation failed")

        // Mirror the committed MoneroCore.connectDaemon exactly: full URL
        // string, use_ssl=true for https (scheme-derived), no proxy,
        // untrusted.
        let initOK = MONERO_Wallet_init(
            wallet, "https://node.monero.one:443", 0, "", "", true, false, ""
        )
        XCTAssertTrue(initOK, "daemon init failed: \(walletError(wallet))")
        MONERO_Wallet_setTrustedDaemon(wallet, false)

        // WalletImpl::doRefresh silently no-ops until daemonSynced() sees a
        // real daemon poll, so wait for the daemon height before refreshing —
        // calling refresh() straight after init() "succeeds" without doing
        // anything on every library version.
        var daemonHeight: UInt64 = 0
        for _ in 0 ..< 60 {
            daemonHeight = MONERO_Wallet_daemonBlockChainHeight(wallet)
            if daemonHeight > restoreHeight { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertGreaterThan(daemonHeight, restoreHeight, "daemon never reported a height: \(walletError(wallet))")

        // Now refresh — from height 3.6M this must walk ~150K hashes via
        // /gethashes.bin before scanning a handful of real blocks. Allow a
        // few rounds; each must end with status 0 and the last must have
        // advanced the wallet past its restore height.
        var height: UInt64 = 0
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let refreshOK = MONERO_Wallet_refresh(wallet)
            let status = MONERO_Wallet_status(wallet)
            height = MONERO_Wallet_blockChainHeight(wallet)
            let error = walletError(wallet)
            print("[GethashesDiag] refreshOK=\(refreshOK) status=\(status) height=\(height)/\(daemonHeight) error='\(error)'")
            XCTAssertTrue(refreshOK, "refresh returned false: \(error)")
            XCTAssertEqual(status, 0, "wallet2 error after refresh: \(error)")
            if height > restoreHeight, MONERO_Wallet_synchronized(wallet) { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertGreaterThan(height, restoreHeight, "wallet never advanced past its restore height")

        MONERO_WalletManager_closeWallet(wm, wallet, false)
    }

    private func walletError(_ wallet: UnsafeMutableRawPointer?) -> String {
        guard let wallet else { return "nil wallet" }
        guard let cstr = MONERO_Wallet_errorString(wallet) else { return "" }
        defer { MONERO_free(UnsafeMutableRawPointer(mutating: cstr)) }
        return String(cString: cstr)
    }
}
