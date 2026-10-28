import CMonero
import HsToolKit
import MoneroKit
import Security
import XCTest
@testable import MoneroOne

/// The password of each wallet2 `.keys` file (docs/wallet-keys-password.md).
/// Builds before this fix used the cache id, which is the folder name and
/// sits in UserDefaults, so anyone with the app container could decrypt the
/// spend key. Now each cache id has 32 random bytes in the Keychain.
/// MoneroKit's WalletPasswordTests cover the re-key of older files.
@MainActor
final class WalletFilePasswordTests: XCTestCase {

    private let keychain = KeychainStorage()
    private var cacheIds: [String] = []

    override func tearDown() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        for id in cacheIds {
            if let dir = support?.appendingPathComponent("MoneroKit/\(id)") {
                try? FileManager.default.removeItem(at: dir)
            }
            SecItemDelete(query(id) as CFDictionary)
        }
        cacheIds = []
    }

    private func newCacheId(_ prefix: String = "") -> String {
        let id = prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        cacheIds.append(id)
        return id
    }

    private func query(_ cacheId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStorage.walletFilePasswordService,
            kSecAttrAccount as String: cacheId
        ]
    }

    private func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { "0123456789abcdef".contains($0) }
    }

    // MARK: - The secret

    func testPasswordIs32RandomBytesAndStaysTheSame() throws {
        let id = newCacheId()
        let password = try keychain.walletFilePassword(cacheId: id)
        XCTAssertTrue(isHex64(password), "not 32 bytes as hex")
        XCTAssertEqual(try keychain.walletFilePassword(cacheId: id), password, "a second open got another password")
        XCTAssertEqual(try KeychainStorage().walletFilePassword(cacheId: id), password)
        XCTAssertFalse(password.contains(id), "the password holds the cache id")
    }

    func testEachWalletHasItsOwnPassword() throws {
        let passwords = try (0..<5).map { _ in try keychain.walletFilePassword(cacheId: newCacheId()) }
        XCTAssertEqual(Set(passwords).count, 5)
        let random = try (0..<5).map { _ in try KeychainStorage.randomWalletFilePassword() }
        XCTAssertEqual(Set(random).count, 5)
        XCTAssertTrue(random.allSatisfy(isHex64))
    }

    /// AfterFirstUnlock so a wallet opens in the background after the first
    /// unlock; ThisDeviceOnly and not synchronizable so no backup, Quick
    /// Start or iCloud Keychain carries it (the files stay behind as well).
    func testItemStaysOnThisDevice() throws {
        let id = newCacheId()
        _ = try keychain.walletFilePassword(cacheId: id)
        var q = query(id)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(q as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
    }

    /// A stored value that is not a password is never replaced: the wallet
    /// fails to open instead of getting files under a new password.
    func testDamagedItemFailsClosed() throws {
        let id = newCacheId()
        var add = query(id)
        add[kSecValueData as String] = Data("not-a-password".utf8)
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)

        XCTAssertThrowsError(try keychain.walletFilePassword(cacheId: id))

        var read = query(id)
        read[kSecReturnData as String] = true
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, Data("not-a-password".utf8), "the damaged item was replaced")
    }

    // MARK: - Delete only with the files

    func testPasswordStaysWhileTheFolderExists() throws {
        let id = newCacheId()
        let password = try keychain.walletFilePassword(cacheId: id)
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let dir = support.appendingPathComponent("MoneroKit/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        keychain.deleteWalletFilePassword(cacheId: id, folder: dir)
        XCTAssertEqual(try keychain.walletFilePassword(cacheId: id), password, "deleted while the files are on disk")

        try FileManager.default.removeItem(at: dir)
        keychain.deleteWalletFilePassword(cacheId: id, folder: dir)
        XCTAssertNotEqual(try keychain.walletFilePassword(cacheId: id), password, "not deleted with the files")
    }

    func testEnvelopeDeleteLeavesWalletPasswords() throws {
        let walletId = newCacheId()
        let envelopeIds = [newCacheId("envelopes/"), newCacheId("envelopes/")]
        let walletPassword = try keychain.walletFilePassword(cacheId: walletId)
        let envelopePasswords = try envelopeIds.map { try keychain.walletFilePassword(cacheId: $0) }

        keychain.deleteWalletFilePasswords(cacheIdPrefix: EnvelopeRuntime.cacheId(for: ""))

        XCTAssertEqual(try keychain.walletFilePassword(cacheId: walletId), walletPassword)
        for (id, old) in zip(envelopeIds, envelopePasswords) {
            XCTAssertNotEqual(try keychain.walletFilePassword(cacheId: id), old)
        }
    }

    // MARK: - The app's wallet files

    /// MoneroWallet asks the Keychain for the password of the wallet it
    /// creates, and a wallet file made with that password does not open
    /// with the cache id (folder name, UserDefaults).
    func testNewWalletFileUsesTheKeychainPassword() async throws {
        let id = newCacheId()
        let seed = WalletManager().generateNewWallet()
        let node = MoneroKit.Node(url: URL(string: "http://localhost:1")!, isTrusted: false)

        // The app's path: create() saves this wallet's Keychain password
        // before the Kit exists. It does not wait for the Kit to start:
        // MoneroKit runs one Kit at a time, and a Kit another test left
        // running would hold this one back.
        let wallet = MoneroWallet()
        try await wallet.create(seed: seed, node: node, cacheIdOverride: id)
        await wallet.stopAsync()
        var read = query(id)
        read[kSecReturnData as String] = true
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess, "create() saved no password")
        let password = try XCTUnwrap((result as? Data).flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(isHex64(password))
        XCTAssertEqual(try keychain.walletFilePassword(cacheId: id), password)

        // The file that password makes. prepareOnly() opens the wallet
        // with no daemon, whatever else runs.
        let kit = try MoneroKit.Kit(
            wallet: MoneroWallet.kitCredentials(for: seed), account: 0, walletId: id,
            walletPassword: password, node: node,
            reachabilityManager: ReachabilityManager(), logger: nil, moneroCoreLogLevel: 0
        )
        await kit.prepareOnly()
        XCTAssertFalse(kit.runtimePrimaryAddress.isEmpty, "the wallet did not open")
        await kit.stopAsync()

        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let keys = support
            .appendingPathComponent("MoneroKit/\(id)/network_\(MoneroKit.NetworkType.mainnet.rawValue)/monero_core/wallet.keys").path
        // verifyWalletPassword aborts the process on a missing file.
        guard FileManager.default.fileExists(atPath: keys) else {
            return XCTFail("no wallet.keys file")
        }
        let wm = MONERO_WalletManagerFactory_getWalletManager()
        XCTAssertTrue(MONERO_WalletManager_verifyWalletPassword(wm, keys, password, true, 1), "the Keychain password does not open the file")
        XCTAssertFalse(MONERO_WalletManager_verifyWalletPassword(wm, keys, id, true, 1), "the cache id opens the file")
    }
}
