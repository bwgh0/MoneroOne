import XCTest
import MoneroKit
@testable import MoneroOne

/// Pins the on-disk wallet cache-id derivation.
///
/// These are golden-value tests on purpose: existing installs have their
/// wallet2 caches at exactly these ids, and the launch-time orphan sweep
/// deletes any directory it doesn't recognize. If any assertion here fails,
/// the change orphans (and the sweep then deletes) every user's synced
/// cache — including per-transaction keys, which no rescan can rebuild.
/// Do not "fix" these expected values to make a refactor pass.
final class WalletCacheIdTests: XCTestCase {

    private let seedPhrase = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"

    // MARK: - Golden values (SHA-256 prefix, first 16 bytes hex)

    func testMainnetNoReset() {
        XCTAssertEqual(
            MoneroWallet.walletCacheId(seedPhrase: seedPhrase, resetSuffix: nil, networkType: .mainnet),
            "7d096de9fba274aec300d6f20144994b"
        )
    }

    func testMainnetResetCount1() {
        XCTAssertEqual(
            MoneroWallet.walletCacheId(seedPhrase: seedPhrase, resetSuffix: "1", networkType: .mainnet),
            "7c5afbba0bd076f557ed4caf18cc5071"
        )
    }

    func testTestnetNoReset() {
        XCTAssertEqual(
            MoneroWallet.walletCacheId(seedPhrase: seedPhrase, resetSuffix: nil, networkType: .testnet),
            "5ae4963d8daa1fe7047c21160a014cc5"
        )
    }

    func testTestnetResetCount1() {
        XCTAssertEqual(
            MoneroWallet.walletCacheId(seedPhrase: seedPhrase, resetSuffix: "1", networkType: .testnet),
            "303af17252328279a6013226097afe92"
        )
    }

    // MARK: - Formula invariants

    /// Pre-multi-wallet installs stored ids from `stableWalletId(seed:)`.
    /// The unified derivation must keep producing the identical id for the
    /// no-reset mainnet case or every upgraded install re-syncs from zero.
    func testMainnetNoResetMatchesLegacyDerivation() {
        let words = seedPhrase.split(separator: " ").map(String.init)
        XCTAssertEqual(
            MoneroWallet.walletCacheId(seedPhrase: seedPhrase, resetSuffix: nil, networkType: .mainnet),
            MoneroWallet.stableWalletId(for: words)
        )
    }

    func testResetChangesId() {
        let base = MoneroWallet.walletCacheId(seedPhrase: seedPhrase, resetSuffix: nil, networkType: .mainnet)
        let reset = MoneroWallet.walletCacheId(seedPhrase: seedPhrase, resetSuffix: "1", networkType: .mainnet)
        XCTAssertNotEqual(base, reset, "Reset must map to a fresh cache dir")
    }

    func testIdShapeIsSweepCompatible() {
        // The orphan sweep only considers 32-char hex names. Every id we
        // generate must have that shape or stale caches would never be
        // collected.
        for id in [
            MoneroWallet.walletCacheId(seedPhrase: seedPhrase, resetSuffix: "3", networkType: .testnet),
            MoneroWallet.viewOnlyCacheId(address: "44hMjpSS", viewKey: "abc123", networkType: .mainnet),
        ] {
            XCTAssertEqual(id.count, 32)
            XCTAssertTrue(id.allSatisfy(\.isHexDigit))
        }
    }

    func testViewOnlyGoldenValue() {
        // SHA-256("addr" + "key" + "_testnet") prefix — pins the view-only
        // (and Trezor watch-cache) derivation.
        XCTAssertEqual(
            MoneroWallet.viewOnlyCacheId(address: "addr", viewKey: "key", networkType: .testnet),
            MoneroWallet.stableWalletId(for: "addr" + "key" + "_testnet")
        )
        XCTAssertEqual(
            MoneroWallet.viewOnlyCacheId(address: "addr", viewKey: "key", networkType: .mainnet),
            MoneroWallet.stableWalletId(for: "addrkey")
        )
    }
}

/// Decision-table tests for the launch-time orphan cache sweep.
final class OrphanCacheSweepTests: XCTestCase {

    private let live = "7d096de9fba274aec300d6f20144994b"
    private let orphan = "deadbeefdeadbeefdeadbeefdeadbeef"

    func testOrphanHexDirIsSwept() {
        let doomed = WalletManager.orphanedCacheDirNames(
            entries: [live, orphan],
            knownIds: [live],
            allWalletIdsKnown: true
        )
        XCTAssertEqual(doomed, [orphan])
    }

    func testKnownIdsAreKept() {
        let doomed = WalletManager.orphanedCacheDirNames(
            entries: [live],
            knownIds: [live],
            allWalletIdsKnown: true
        )
        XCTAssertTrue(doomed.isEmpty)
    }

    /// The Julian regression: while any wallet's ids are unknown (legacy
    /// WalletInfo before first unlock), the sweep must delete NOTHING —
    /// the unrecognized dir may be that wallet's live cache.
    func testUnresolvedWalletIdsDisableSweepEntirely() {
        let doomed = WalletManager.orphanedCacheDirNames(
            entries: [orphan, "cafebabecafebabecafebabecafebabe"],
            knownIds: [],
            allWalletIdsKnown: false
        )
        XCTAssertTrue(doomed.isEmpty)
    }

    func testNonHex32NamesAreNeverSwept() {
        let doomed = WalletManager.orphanedCacheDirNames(
            entries: [
                ".DS_Store",
                "metadata",
                "deadbeef",                            // hex but short
                "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",    // 32 chars, not hex
                String(repeating: "a", count: 33),     // hex, wrong length
            ],
            knownIds: [],
            allWalletIdsKnown: true
        )
        XCTAssertTrue(doomed.isEmpty)
    }

    func testEmptyDirectoryIsFine() {
        XCTAssertTrue(WalletManager.orphanedCacheDirNames(entries: [], knownIds: [], allWalletIdsKnown: true).isEmpty)
    }
}
