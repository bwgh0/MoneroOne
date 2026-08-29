import XCTest
@testable import MoneroOne

/// Regression tests for the second SlowBearDigger remediation pass
/// (verification sweep 2026-07-29/30).
///
/// Each test names the finding it guards. Where the audit's claim turned out to
/// be inaccurate, the test pins the *correct* behavior rather than the audit's
/// description of it.

// MARK: - H6: PIN verifier must not be the seed-encryption key

final class PinVerifierSeparationTests: XCTestCase {

    private var keychain: KeychainStorage!
    private let seed = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
    private let pin = "135790"

    override func setUpWithError() throws {
        keychain = KeychainStorage()
        keychain.deleteAll()
    }

    override func tearDownWithError() throws {
        keychain.deleteAll()
    }

    /// The core of H6: the artifact stored for PIN verification used to be
    /// byte-identical to the AES-GCM key protecting the seed, so a single
    /// keychain read yielded the plaintext seed and the 600k-iteration PBKDF2
    /// work factor protected nothing.
    func testStoredPinHashIsNotTheEncryptionKey() throws {
        try keychain.saveSeed(seed, pin: pin)

        let storedHash = try XCTUnwrap(keychain.debugStoredPinHash())
        let encryptionKey = try XCTUnwrap(keychain.debugEncryptionKey(pin: pin))

        XCTAssertEqual(storedHash.count, 32)
        XCTAssertEqual(encryptionKey.count, 32)
        XCTAssertNotEqual(
            storedHash, encryptionKey,
            "Stored PIN verifier must not equal the seed-encryption key — that makes a keychain read sufficient to decrypt the seed"
        )
    }

    /// The separation must not have broken unlocking.
    func testCorrectPinStillUnlocksAndWrongPinStillFails() throws {
        try keychain.saveSeed(seed, pin: pin)
        XCTAssertEqual(try keychain.getSeed(pin: pin), seed)
        XCTAssertNil(try? keychain.getSeed(pin: "999999"))
    }

    /// Wallets saved before the HKDF split have the raw PBKDF2 master key as
    /// their stored hash. Those users must still be able to unlock, and the
    /// stored hash should be upgraded in place so the exposure goes away
    /// without anyone re-entering anything.
    func testLegacyMasterKeyHashStillVerifiesAndIsUpgraded() throws {
        try keychain.saveSeed(seed, pin: pin)

        // Simulate a pre-fix install: overwrite the verifier with the raw
        // master key, which is what the old `hashPin` returned.
        let masterKey = try XCTUnwrap(keychain.debugEncryptionKey(pin: pin))
        keychain.debugOverwriteStoredPinHash(masterKey)
        XCTAssertEqual(keychain.debugStoredPinHash(), masterKey, "precondition")

        // Unlock must still work…
        XCTAssertEqual(try keychain.getSeed(pin: pin), seed)

        // …and the stored artifact must no longer be the key.
        let upgraded = try XCTUnwrap(keychain.debugStoredPinHash())
        XCTAssertNotEqual(upgraded, masterKey, "Legacy hash should be upgraded to the HKDF verifier on successful unlock")
        XCTAssertEqual(try keychain.getSeed(pin: pin), seed, "Still unlocks after upgrade")
    }
}

// MARK: - VULN-07 residual: price sanity bounds

final class PriceSanityTests: XCTestCase {

    /// A price this far off is bad data, and it feeds fiat→XMR conversion for
    /// the amount that actually gets sent.
    func testImplausiblePricesRejected() {
        XCTAssertFalse(PriceService.isPlausiblePrice(0), "zero would divide to infinity")
        XCTAssertFalse(PriceService.isPlausiblePrice(-100))
        XCTAssertFalse(PriceService.isPlausiblePrice(0.01), "the audit's MITM value")
        XCTAssertFalse(PriceService.isPlausiblePrice(10_000_000))
        XCTAssertFalse(PriceService.isPlausiblePrice(.nan))
        XCTAssertFalse(PriceService.isPlausiblePrice(.infinity))
    }

    /// Real prices across supported fiat currencies must pass — including
    /// low-value-unit currencies, so the bounds stay deliberately wide.
    func testPlausiblePricesAccepted() {
        for price in [1.0, 150.0, 200.0, 342.87, 25_000.0, 500_000.0] {
            XCTAssertTrue(PriceService.isPlausiblePrice(price), "\(price) should be accepted")
        }
    }
}

// MARK: - Diagnostic log credential redaction

/// The diagnostic log is exported and emailed to support. Node URLs are the
/// most useful thing in it, but a custom node URL can carry `user:pass@`.
final class DiagnosticLogRedactionTests: XCTestCase {

    func testCredentialsStrippedFromNodeURL() {
        let redacted = DiagnosticLog.redactingCredentials(
            in: "Reachability check: https://alice:s3cr3t@node.example.com:18081"
        )
        XCTAssertEqual(redacted, "Reachability check: https://***@node.example.com:18081")
        XCTAssertFalse(redacted.contains("s3cr3t"))
        XCTAssertFalse(redacted.contains("alice"))
    }

    func testPlainURLUntouched() {
        let line = "Node reachable: https://node.monero.one:443"
        XCTAssertEqual(DiagnosticLog.redactingCredentials(in: line), line,
                       "Node URLs themselves must survive — they're the point of the log")
    }

    func testNonURLLineUntouched() {
        let line = "Stage: connecting → synced (daemon=3646773, wallet=3646773)"
        XCTAssertEqual(DiagnosticLog.redactingCredentials(in: line), line)
    }

    /// A colon in the message must not be mistaken for credentials.
    func testTimestampsAndPortsNotMangled() {
        let line = "TLS strict: OK (https://node.monero.one:443) at 12:04:31"
        XCTAssertEqual(DiagnosticLog.redactingCredentials(in: line), line)
    }
}

// MARK: - Clipboard lifetime (H2)

final class SecureClipboardPolicyTests: XCTestCase {

    /// The audit found a 300s window; the real problem was that the clear task
    /// was app-side only, so a force-quit left the seed there indefinitely.
    func testSecretLifetimeIsShort() {
        XCTAssertLessThanOrEqual(
            SecureClipboard.secretLifetime, 60,
            "Seed/view-key clipboard lifetime should be under a minute"
        )
        XCTAssertGreaterThan(
            SecureClipboard.secretLifetime, 10,
            "…but long enough to paste into a password manager"
        )
    }
}
