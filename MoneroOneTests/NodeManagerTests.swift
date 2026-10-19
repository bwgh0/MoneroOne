import Combine
import CryptoKit
import Network
import XCTest
@testable import MoneroOne

/// The node settings a NodeManager reads and writes in UserDefaults. The
/// tests run inside MoneroOne.app and share its UserDefaults, so a test that
/// changes them saves them first and puts them back after it. A test run
/// then leaves the simulator's own node list, selection and proxy as they
/// were.
private struct SavedNodeSettings {
    static let keys = [
        "isTestnet",
        "selectedNodeURL", "selectedTestnetNodeURL",
        "customNodes", "customTestnetNodes",
        "autoSelectNode", "autoSelectTestnetNode",
        "proxyAddress", "selectedProxyAddress", "customProxies",
        "nodeCredsMigratedToKeychain",
    ]

    private let values = SavedNodeSettings.keys.map { UserDefaults.standard.object(forKey: $0) }

    /// Puts each saved value back, and removes a key that had none.
    func restore() {
        for (key, value) in zip(Self.keys, values) {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

@MainActor
final class NodeManagerTests: XCTestCase {

    var nodeManager: NodeManager!
    private var fake: FakeNodeKeychain!
    private var savedSettings: SavedNodeSettings!

    override func setUp() async throws {
        // Start from no saved selection and no custom nodes. The fake
        // Keychain keeps selectNode from clearing the app's own node login.
        savedSettings = SavedNodeSettings()
        UserDefaults.standard.removeObject(forKey: "selectedNodeURL")
        UserDefaults.standard.removeObject(forKey: "customNodes")
        fake = FakeNodeKeychain()
        nodeManager = NodeManager(keychain: fake.keychain)
    }

    override func tearDown() async throws {
        nodeManager = nil
        fake = nil
        savedSettings.restore()
    }

    // MARK: - Default Nodes Tests

    func testDefaultNodesExist() {
        XCTAssertFalse(NodeManager.defaultNodes.isEmpty, "Should have default nodes")
        XCTAssertGreaterThanOrEqual(NodeManager.defaultNodes.count, 3, "Should have at least 3 default nodes")
    }

    func testDefaultNodesHaveValidURLs() {
        for node in NodeManager.defaultNodes {
            XCTAssertFalse(node.url.isEmpty, "Node URL should not be empty")
            XCTAssertNotNil(URL(string: node.url), "Node URL should be valid: \(node.url)")
            XCTAssertTrue(node.url.hasPrefix("https://"), "Node URL should use HTTPS: \(node.url)")
        }
    }

    func testDefaultNodesHaveNames() {
        for node in NodeManager.defaultNodes {
            XCTAssertFalse(node.name.isEmpty, "Node should have a name")
        }
    }

    // MARK: - Node Selection Tests

    func testInitialSelectedNodeIsFirstDefault() {
        let firstDefault = NodeManager.defaultNodes[0]
        XCTAssertEqual(nodeManager.selectedNode.url, firstDefault.url, "Initial selection should be first default node")
    }

    func testSelectNodeUpdatesSelection() {
        let secondNode = NodeManager.defaultNodes[1]
        nodeManager.selectNode(secondNode)

        XCTAssertEqual(nodeManager.selectedNode.url, secondNode.url, "Selected node should be updated")
    }

    func testSelectNodePersistsToUserDefaults() {
        let secondNode = NodeManager.defaultNodes[1]
        nodeManager.selectNode(secondNode)

        let savedURL = UserDefaults.standard.string(forKey: "selectedNodeURL")
        XCTAssertEqual(savedURL, secondNode.url, "Selection should be persisted to UserDefaults")
    }

    func testSelectionPersistsAcrossInstances() {
        let secondNode = NodeManager.defaultNodes[1]
        nodeManager.selectNode(secondNode)

        // Create new instance
        let newManager = NodeManager(keychain: fake.keychain)
        XCTAssertEqual(newManager.selectedNode.url, secondNode.url, "Selection should persist across instances")
    }

    // MARK: - Custom Node Tests

    func testAddCustomNode() {
        let customURL = "https://custom.node.com:18081"
        let customName = "My Custom Node"

        nodeManager.addCustomNode(name: customName, url: customURL)

        XCTAssertEqual(nodeManager.customNodes.count, 1, "Should have 1 custom node")
        XCTAssertEqual(nodeManager.customNodes[0].name, customName)
        XCTAssertEqual(nodeManager.customNodes[0].url, customURL)
    }

    func testRemoveCustomNode() {
        nodeManager.addCustomNode(name: "Test", url: "https://test.com:18081")
        let addedNode = nodeManager.customNodes[0]

        nodeManager.removeCustomNode(addedNode)

        XCTAssertTrue(nodeManager.customNodes.isEmpty, "Custom nodes should be empty after removal")
    }

    func testRemoveSelectedCustomNodeSwitchesToDefault() {
        let customURL = "https://custom.node.com:18081"
        nodeManager.addCustomNode(name: "Custom", url: customURL)
        let customNode = nodeManager.customNodes[0]

        nodeManager.selectNode(customNode)
        nodeManager.removeCustomNode(customNode)

        XCTAssertEqual(nodeManager.selectedNode.url, NodeManager.defaultNodes[0].url,
                       "Should switch to default node when selected custom node is removed")
    }

    func testCustomNodesPersistAcrossInstances() {
        nodeManager.addCustomNode(name: "Persistent", url: "https://persistent.com:18081")

        let newManager = NodeManager(keychain: fake.keychain)
        XCTAssertEqual(newManager.customNodes.count, 1, "Custom nodes should persist")
        XCTAssertEqual(newManager.customNodes[0].name, "Persistent")
    }

    // MARK: - Edit Reconnect Tests

    private let editedNode = MoneroNode(name: "Home", url: "https://home.node:18089", login: "user", password: "pass")

    func testRenameDoesNotNeedReconnect() {
        let renamed = MoneroNode(name: "Basement", url: editedNode.url, login: "user", password: "pass")
        XCTAssertFalse(NodeManager.needsReconnect(from: editedNode, to: renamed),
                       "A rename alone should keep the wallet on its connection")
    }

    func testURLChangeNeedsReconnect() {
        let moved = MoneroNode(name: editedNode.name, url: "https://other.node:18089", login: "user", password: "pass")
        XCTAssertTrue(NodeManager.needsReconnect(from: editedNode, to: moved))
    }

    func testLoginChangeNeedsReconnect() {
        let newUser = MoneroNode(name: editedNode.name, url: editedNode.url, login: "admin", password: "pass")
        let newPassword = MoneroNode(name: editedNode.name, url: editedNode.url, login: "user", password: "secret")
        let noLogin = MoneroNode(name: editedNode.name, url: editedNode.url)
        XCTAssertTrue(NodeManager.needsReconnect(from: editedNode, to: newUser))
        XCTAssertTrue(NodeManager.needsReconnect(from: editedNode, to: newPassword))
        XCTAssertTrue(NodeManager.needsReconnect(from: editedNode, to: noLogin))
    }

    func testEmptyLoginMatchesNoLogin() {
        // The edit sheet saves an empty field as nil.
        let stored = MoneroNode(name: "Open", url: "https://open.node:18089", login: "", password: "")
        let renamed = MoneroNode(name: "Open Node", url: stored.url)
        XCTAssertFalse(NodeManager.needsReconnect(from: stored, to: renamed))
    }
}

// MARK: - Node Login Keychain Tests

/// Stands in for the Keychain: items in a dictionary, with writes that can fail.
private final class FakeNodeKeychain {
    var items: [String: Data] = [:]
    /// Accounts whose writes fail, as on a locked or broken Keychain.
    var failingAccounts: Set<String> = []
    /// Writes report success but store nothing, so only the read-back catches them.
    var dropsWrites = false
    /// Reads return nothing, as on a Keychain that is still locked.
    var failsReads = false
    private(set) var writes = 0

    var keychain: NodeCredentialStore.Keychain {
        NodeCredentialStore.Keychain(
            read: { self.failsReads ? nil : self.items[$0] },
            write: { account, data in
                self.writes += 1
                guard !self.failingAccounts.contains(account) else { return false }
                if !self.dropsWrites { self.items[account] = data }
                return true
            },
            delete: { self.items[$0] = nil }
        )
    }
}

/// A custom node in the shape that builds before the Keychain move encoded
/// it, login included.
private struct LegacyNode: Codable {
    let name: String
    let url: String
    var isTrusted = false
    var login: String? = nil
    var password: String? = nil
}

@MainActor
final class NodeLoginMigrationTests: XCTestCase {

    private let suiteName = "one.monero.MoneroOneTests.NodeLoginMigration"
    private var defaults: UserDefaults!
    private var fake: FakeNodeKeychain!

    private let home = "https://home.node:18089"
    private let lab = "http://lab.node:18081"
    private let open = "https://open.node:18089"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        fake = FakeNodeKeychain()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        fake = nil
    }

    private func listKey(_ testnet: Bool) -> String {
        testnet ? "customTestnetNodes" : "customNodes"
    }

    private func storeLegacyList(_ nodes: [LegacyNode], testnet: Bool = false) throws {
        defaults.set(try JSONEncoder().encode(nodes), forKey: listKey(testnet))
    }

    /// The stored list as plain JSON objects.
    private func storedEntries(testnet: Bool = false) throws -> [[String: Any]] {
        let data = try XCTUnwrap(defaults.data(forKey: listKey(testnet)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func item(_ url: String, testnet: Bool = false) -> NodeCredentials? {
        NodeCredentialStore.loadNode(url: url, isTestnet: testnet, keychain: fake.keychain)
    }

    private func migrate() {
        NodeManager.migrateCustomNodeLogins(defaults: defaults, keychain: fake.keychain)
    }

    func testMigrationMovesLoginsToKeychain() throws {
        try storeLegacyList([
            LegacyNode(name: "Home", url: home, login: "alice", password: "hunter2"),
            LegacyNode(name: "Open", url: open),
            LegacyNode(name: "Lab", url: lab, isTrusted: true, login: "bob", password: "s3cret"),
        ])

        migrate()

        XCTAssertEqual(item(home), NodeCredentials(login: "alice", password: "hunter2"))
        XCTAssertEqual(item(lab), NodeCredentials(login: "bob", password: "s3cret"))
        XCTAssertNil(item(open))
        for entry in try storedEntries() {
            XCTAssertNil(entry["login"])
            XCTAssertNil(entry["password"])
        }
        let data = try XCTUnwrap(defaults.data(forKey: "customNodes"))
        let raw = String(decoding: data, as: UTF8.self)
        for secret in ["alice", "hunter2", "bob", "s3cret"] {
            XCTAssertFalse(raw.contains(secret), "The list must hold no login after the move")
        }
        // Everything else in the list stays as it was.
        let nodes = try JSONDecoder().decode([LegacyNode].self, from: data)
        XCTAssertEqual(nodes.map(\.name), ["Home", "Open", "Lab"])
        XCTAssertEqual(nodes.map(\.url), [home, open, lab])
        XCTAssertEqual(nodes.map(\.isTrusted), [false, false, true])
    }

    func testMigrationTwiceIsNoOp() throws {
        try storeLegacyList([
            LegacyNode(name: "Home", url: home, login: "alice", password: "hunter2"),
            LegacyNode(name: "Open", url: open),
        ])
        migrate()
        let list = defaults.data(forKey: "customNodes")
        let items = fake.items
        let writes = fake.writes

        migrate()

        XCTAssertEqual(defaults.data(forKey: "customNodes"), list)
        XCTAssertEqual(fake.items, items)
        XCTAssertEqual(fake.writes, writes, "A second run writes nothing")
    }

    func testFailedKeychainWriteKeepsLoginInList() throws {
        try storeLegacyList([
            LegacyNode(name: "Home", url: home, login: "alice", password: "hunter2"),
            LegacyNode(name: "Lab", url: lab, login: "bob", password: "s3cret"),
        ])
        fake.failingAccounts = [NodeCredentialStore.nodeAccount(url: lab, isTestnet: false)]

        migrate()

        XCTAssertEqual(item(home), NodeCredentials(login: "alice", password: "hunter2"))
        XCTAssertNil(item(lab))
        var entries = try storedEntries()
        XCTAssertNil(entries[0]["login"])
        XCTAssertEqual(entries[1]["login"] as? String, "bob", "A login whose write failed stays in the list")
        XCTAssertEqual(entries[1]["password"] as? String, "s3cret")

        // The next launch, with a working Keychain, finishes the move.
        fake.failingAccounts = []
        migrate()

        XCTAssertEqual(item(lab), NodeCredentials(login: "bob", password: "s3cret"))
        entries = try storedEntries()
        XCTAssertNil(entries[1]["login"])
        XCTAssertNil(entries[1]["password"])
    }

    func testWriteThatDoesNotReadBackKeepsLogin() throws {
        try storeLegacyList([LegacyNode(name: "Home", url: home, login: "alice", password: "hunter2")])
        fake.dropsWrites = true

        migrate()

        XCTAssertNil(item(home))
        XCTAssertEqual(try storedEntries()[0]["login"] as? String, "alice")
        XCTAssertEqual(try storedEntries()[0]["password"] as? String, "hunter2")
    }

    func testSelectedNodeKeychainLoginWins() throws {
        try storeLegacyList([
            LegacyNode(name: "Home", url: home, login: "alice", password: "old"),
            LegacyNode(name: "Home Again", url: home, login: "bob", password: "other"),
        ])
        defaults.set(home, forKey: "selectedNodeURL")
        NodeCredentialStore.save(login: "alice", password: "new", isTestnet: false, keychain: fake.keychain)

        migrate()

        XCTAssertEqual(item(home), NodeCredentials(login: "alice", password: "new"))
        for entry in try storedEntries() {
            XCTAssertNil(entry["login"], "Every copy of the URL uses its one item")
            XCTAssertNil(entry["password"])
        }
    }

    func testListLoginWinsOverAnOlderItem() throws {
        // After a downgrade, an earlier build saved a new login in the list.
        // The item still holds the old one.
        try storeLegacyList([LegacyNode(name: "Home", url: home, login: "alice", password: "changed")])
        NodeCredentialStore.saveNode(url: home, credentials: NodeCredentials(login: "alice", password: "hunter2"),
                                     isTestnet: false, keychain: fake.keychain)

        migrate()

        XCTAssertEqual(item(home), NodeCredentials(login: "alice", password: "changed"))
        XCTAssertNil(try storedEntries()[0]["password"])
    }

    func testEmptySlotTakesTheSelectedNodesItem() throws {
        // After a downgrade, an earlier build selected the node again without
        // its login, which cleared the login the wallet reads. The item kept it.
        let login = NodeCredentials(login: "alice", password: "hunter2")
        try storeLegacyList([LegacyNode(name: "Home", url: home)])
        defaults.set(home, forKey: "selectedNodeURL")
        NodeCredentialStore.saveNode(url: home, credentials: login, isTestnet: false, keychain: fake.keychain)

        migrate()

        let kit = NodeCredentialStore.load(isTestnet: false, keychain: fake.keychain)
        XCTAssertEqual(NodeCredentials(login: kit.login, password: kit.password), login)
    }

    func testEmptySlotWaitsWhileTheListHoldsANewerLogin() throws {
        // The item holds an old login, and the write of the newer one fails.
        let newer = NodeCredentials(login: "alice", password: "changed")
        try storeLegacyList([LegacyNode(name: "Home", url: home, login: "alice", password: "changed")])
        defaults.set(home, forKey: "selectedNodeURL")
        NodeCredentialStore.saveNode(url: home, credentials: NodeCredentials(login: "alice", password: "hunter2"),
                                     isTestnet: false, keychain: fake.keychain)
        fake.failingAccounts = [NodeCredentialStore.nodeAccount(url: home, isTestnet: false)]

        migrate()

        XCTAssertNil(NodeCredentialStore.load(isTestnet: false, keychain: fake.keychain).login,
                     "The old item must not reach the wallet, or it would win on the next launch")
        XCTAssertEqual(try storedEntries()[0]["password"] as? String, "changed")

        // The next launch, with a working Keychain, gives the newer login to all.
        fake.failingAccounts = []
        migrate()

        XCTAssertEqual(item(home), newer)
        let kit = NodeCredentialStore.load(isTestnet: false, keychain: fake.keychain)
        XCTAssertEqual(NodeCredentials(login: kit.login, password: kit.password), newer)
        XCTAssertNil(try storedEntries()[0]["password"])
    }

    func testEmptySlotStaysEmptyForAnUnlistedURL() throws {
        // An item that no listed node uses never reaches the wallet.
        try storeLegacyList([LegacyNode(name: "Open", url: open)])
        defaults.set(home, forKey: "selectedNodeURL")
        NodeCredentialStore.saveNode(url: home, credentials: NodeCredentials(login: "alice", password: "hunter2"),
                                     isTestnet: false, keychain: fake.keychain)

        migrate()

        let kit = NodeCredentialStore.load(isTestnet: false, keychain: fake.keychain)
        XCTAssertNil(kit.login)
        XCTAssertNil(kit.password)
    }

    func testSelectedNodeWithoutKeychainLoginUsesList() throws {
        // A phone restored from a backup: the list kept the login, the Keychain did not.
        try storeLegacyList([LegacyNode(name: "Home", url: home, login: "alice", password: "hunter2")])
        defaults.set(home, forKey: "selectedNodeURL")

        migrate()

        XCTAssertEqual(item(home), NodeCredentials(login: "alice", password: "hunter2"))
        XCTAssertNil(try storedEntries()[0]["login"])
    }

    func testTestnetListMovesToTestnetItems() throws {
        try storeLegacyList([LegacyNode(name: "Home", url: home, login: "alice", password: "hunter2")], testnet: true)

        migrate()

        XCTAssertEqual(item(home, testnet: true), NodeCredentials(login: "alice", password: "hunter2"))
        XCTAssertNil(item(home, testnet: false))
        XCTAssertNil(try storedEntries(testnet: true)[0]["login"])
    }

    func testURLListedTwiceGetsTheLastCopysLogin() throws {
        try storeLegacyList([
            LegacyNode(name: "Home", url: home, login: "alice", password: "hunter2"),
            LegacyNode(name: "Home Again", url: home, login: "bob", password: "s3cret"),
        ])

        migrate()
        let writes = fake.writes
        migrate()

        // One login per URL. Add appends, so the last copy has the newest login.
        XCTAssertEqual(item(home), NodeCredentials(login: "bob", password: "s3cret"))
        for entry in try storedEntries() {
            XCTAssertNil(entry["login"])
            XCTAssertNil(entry["password"])
        }
        XCTAssertEqual(fake.writes, writes, "A second run writes nothing")
    }

    func testURLListedTwiceWithTheItemsLoginLeavesTheList() throws {
        let login = NodeCredentials(login: "alice", password: "hunter2")
        try storeLegacyList([
            LegacyNode(name: "Home", url: home),
            LegacyNode(name: "Home Again", url: home, login: "alice", password: "hunter2"),
        ])
        NodeCredentialStore.saveNode(url: home, credentials: login, isTestnet: false, keychain: fake.keychain)
        let writesBefore = fake.writes

        migrate()

        XCTAssertEqual(item(home), login)
        XCTAssertNil(try storedEntries()[1]["login"])
        XCTAssertNil(try storedEntries()[1]["password"])
        XCTAssertEqual(fake.writes, writesBefore, "The item that the first copy uses stays as it is")
    }

    func testEmptyLoginFieldsGoWithoutWrites() throws {
        try storeLegacyList([LegacyNode(name: "Open", url: open, login: "", password: "")])

        migrate()

        XCTAssertNil(item(open))
        XCTAssertNil(try storedEntries()[0]["login"])
        XCTAssertEqual(fake.writes, 0)
    }

    func testMigratedListStillDecodesInEarlierBuilds() throws {
        // After a downgrade, an earlier build reads the list in the old shape.
        try storeLegacyList([LegacyNode(name: "Home", url: home, login: "alice", password: "hunter2")])

        migrate()

        let data = try XCTUnwrap(defaults.data(forKey: "customNodes"))
        let nodes = try JSONDecoder().decode([LegacyNode].self, from: data)
        XCTAssertEqual(nodes.first?.url, home)
        XCTAssertNil(nodes.first?.login)
    }
}

@MainActor
final class NodeLoginKeychainTests: XCTestCase {

    private var fake: FakeNodeKeychain!
    private var manager: NodeManager!

    private let home = "https://home.node:18089"
    private let moved = "https://moved.node:18089"
    private let keys = ["selectedNodeURL", "customNodes", "isTestnet"]
    private var savedSettings: SavedNodeSettings!

    override func setUp() async throws {
        savedSettings = SavedNodeSettings()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        fake = FakeNodeKeychain()
        manager = NodeManager(keychain: fake.keychain)
    }

    override func tearDown() async throws {
        manager = nil
        fake = nil
        savedSettings.restore()
    }

    private var storedList: String {
        String(decoding: UserDefaults.standard.data(forKey: "customNodes") ?? Data(), as: UTF8.self)
    }

    private func item(_ url: String) -> NodeCredentials? {
        NodeCredentialStore.loadNode(url: url, isTestnet: false, keychain: fake.keychain)
    }

    private func addHome() {
        manager.addCustomNode(name: "Home", url: home, login: "alice", password: "hunter2")
    }

    func testAddWritesItemAndKeepsListFree() {
        addHome()

        XCTAssertEqual(item(home), NodeCredentials(login: "alice", password: "hunter2"))
        for text in ["alice", "hunter2", "login", "password"] {
            XCTAssertFalse(storedList.contains(text), "The list in UserDefaults must not hold \(text)")
        }
        XCTAssertTrue(manager.customNodes[0].hasCredentials, "The row keeps its lock icon")
    }

    func testListLoadsLoginsFromKeychain() {
        addHome()

        let reloaded = NodeManager(keychain: fake.keychain)

        XCTAssertEqual(reloaded.customNodes.first?.login, "alice")
        XCTAssertEqual(reloaded.customNodes.first?.password, "hunter2")
    }

    func testEditPrefillsFromKeychain() {
        addHome()

        let prefilled = manager.nodeForEditing(MoneroNode(name: "Home", url: home))

        XCTAssertEqual(prefilled.login, "alice")
        XCTAssertEqual(prefilled.password, "hunter2")
    }

    func testEditUpdatesItem() {
        addHome()

        manager.updateCustomNode(oldURL: home, name: "Home", url: home, login: "bob", password: "s3cret")

        XCTAssertEqual(item(home), NodeCredentials(login: "bob", password: "s3cret"))
        XCTAssertFalse(storedList.contains("s3cret"))
    }

    func testEditRemovingLoginRemovesItem() {
        addHome()

        manager.updateCustomNode(oldURL: home, name: "Home", url: home, login: nil, password: nil)

        XCTAssertNil(item(home))
        XCTAssertFalse(manager.customNodes[0].hasCredentials)
    }

    func testURLChangeMovesItem() {
        addHome()

        manager.updateCustomNode(oldURL: home, name: "Home", url: moved, login: "alice", password: "hunter2")

        XCTAssertEqual(item(moved), NodeCredentials(login: "alice", password: "hunter2"))
        XCTAssertNil(item(home), "The old URL keeps no item")
        XCTAssertFalse(storedList.contains("hunter2"))
    }

    func testURLChangeWithFailedWriteKeepsLogin() {
        addHome()
        fake.failingAccounts = [NodeCredentialStore.nodeAccount(url: moved, isTestnet: false)]

        manager.updateCustomNode(oldURL: home, name: "Home", url: moved, login: "alice", password: "hunter2")

        XCTAssertNotNil(item(home), "The old item stays until the new one holds the login")
        XCTAssertTrue(storedList.contains("hunter2"), "The list keeps the login until a write goes through")
    }

    func testDeleteRemovesItem() {
        addHome()

        manager.removeCustomNode(manager.customNodes[0])

        XCTAssertNil(item(home))
    }

    func testFailedWriteOnAddKeepsLoginInList() {
        fake.failingAccounts = [NodeCredentialStore.nodeAccount(url: home, isTestnet: false)]

        addHome()

        XCTAssertNil(item(home))
        XCTAssertTrue(storedList.contains("hunter2"), "The list keeps the login until a write goes through")
        XCTAssertEqual(NodeManager(keychain: fake.keychain).customNodes.first?.password, "hunter2")

        // A later launch with a working Keychain moves it.
        fake.failingAccounts = []
        NodeManager.migrateCustomNodeLogins(keychain: fake.keychain)

        XCTAssertEqual(item(home), NodeCredentials(login: "alice", password: "hunter2"))
        XCTAssertFalse(storedList.contains("hunter2"))
    }

    // MARK: One login per URL

    private func assertListHoldsNoLogin(file: StaticString = #filePath, line: UInt = #line) {
        for text in ["alice", "hunter2", "bob", "s3cret", "login", "password"] {
            XCTAssertFalse(storedList.contains(text), "The list in UserDefaults must not hold \(text)", file: file, line: line)
        }
    }

    func testAddingAURLAgainGivesEveryCopyTheNewLogin() {
        addHome()

        manager.addCustomNode(name: "Home Again", url: home, login: "bob", password: "s3cret")

        let login = NodeCredentials(login: "bob", password: "s3cret")
        XCTAssertEqual(item(home), login)
        XCTAssertEqual(manager.customNodes.map(\.credentials), [login, login])
        assertListHoldsNoLogin()
        // The next launch keeps one copy of the URL, with the login.
        XCTAssertEqual(NodeManager(keychain: fake.keychain).customNodes.map(\.credentials), [login])
    }

    func testURLAddedAgainWithoutLoginKeepsItsLogin() {
        addHome()

        manager.addCustomNode(name: "Home Again", url: home)

        let login = NodeCredentials(login: "alice", password: "hunter2")
        XCTAssertEqual(item(home), login)
        XCTAssertEqual(manager.customNodes.map(\.credentials), [login, login])
        assertListHoldsNoLogin()
    }

    func testEditOntoAnotherNodesURLGivesEveryCopyTheLogin() {
        addHome()
        manager.addCustomNode(name: "Lab", url: moved, login: "bob", password: "s3cret")

        manager.updateCustomNode(oldURL: moved, name: "Lab", url: home, login: "bob", password: "s3cret")

        let login = NodeCredentials(login: "bob", password: "s3cret")
        XCTAssertEqual(item(home), login)
        XCTAssertNil(item(moved), "No listed node uses the old URL now")
        XCTAssertEqual(manager.customNodes.map(\.credentials), [login, login])
        assertListHoldsNoLogin()
        XCTAssertEqual(NodeManager(keychain: fake.keychain).customNodes.map(\.credentials), [login])
    }

    func testNodeMovedWithoutLoginOntoAListedURLTakesItsLogin() {
        addHome()
        manager.addCustomNode(name: "Lab", url: moved)

        let saved = manager.updateCustomNode(oldURL: moved, name: "Lab", url: home)

        // The edit sheet selects this node and gives its login to the wallet.
        let login = NodeCredentials(login: "alice", password: "hunter2")
        XCTAssertEqual(saved?.credentials, login)
        XCTAssertEqual(item(home), login)
        XCTAssertEqual(manager.customNodes.map(\.credentials), [login, login])
        assertListHoldsNoLogin()
    }

    func testAddWithoutLoginKeepsTheItemWhenTheLoadReadFailed() {
        addHome()
        fake.failsReads = true
        let reloaded = NodeManager(keychain: fake.keychain)
        XCTAssertFalse(reloaded.customNodes[0].hasCredentials, "The list loaded without the login")
        fake.failsReads = false

        reloaded.addCustomNode(name: "Home Again", url: home)

        let login = NodeCredentials(login: "alice", password: "hunter2")
        XCTAssertEqual(item(home), login, "The item stays")
        XCTAssertEqual(reloaded.customNodes.map(\.credentials), [login, login])
    }

    func testClearingTheLoginOnOneCopyClearsEveryCopy() {
        addHome()
        manager.addCustomNode(name: "Home Again", url: home)

        manager.updateCustomNode(oldURL: home, name: "Home", url: home)

        XCTAssertNil(item(home))
        XCTAssertEqual(manager.customNodes.map(\.credentials), [NodeCredentials.none, NodeCredentials.none])
        XCTAssertEqual(NodeManager(keychain: fake.keychain).customNodes.map(\.credentials), [NodeCredentials.none])
        assertListHoldsNoLogin()
    }

    func testEditOntoTheSelectedURLGivesTheWalletItsLogin() {
        addHome()
        manager.selectNode(manager.customNodes[0])
        manager.addCustomNode(name: "Lab", url: moved, login: "bob", password: "s3cret")

        manager.updateCustomNode(oldURL: moved, name: "Lab", url: home, login: "bob", password: "s3cret")

        let kit = NodeCredentialStore.load(isTestnet: false, keychain: fake.keychain)
        XCTAssertEqual(item(home), NodeCredentials(login: "bob", password: "s3cret"))
        XCTAssertEqual(NodeCredentials(login: kit.login, password: kit.password), item(home))
    }

    func testAddWithoutLoginTakesOverAPendingLogin() {
        // The first write fails, so the login waits in the list.
        fake.failingAccounts = [NodeCredentialStore.nodeAccount(url: home, isTestnet: false)]
        addHome()

        manager.addCustomNode(name: "Home Again", url: home)

        // The new copy takes the waiting login, and both keep it in the list
        // while the write still fails.
        let login = NodeCredentials(login: "alice", password: "hunter2")
        XCTAssertNil(item(home))
        XCTAssertEqual(manager.customNodes.map(\.credentials), [login, login])
        // The next launch keeps one copy, and the login still waits in it.
        XCTAssertEqual(NodeManager(keychain: fake.keychain).customNodes.map(\.credentials), [login])
        XCTAssertTrue(storedList.contains("hunter2"))

        // A later launch with a working Keychain moves it.
        fake.failingAccounts = []
        NodeManager.migrateCustomNodeLogins(keychain: fake.keychain)

        XCTAssertEqual(item(home), login)
        XCTAssertFalse(storedList.contains("hunter2"))
    }

    func testNewLoginOfTheSelectedURLReachesTheWallet() {
        addHome()
        manager.selectNode(manager.customNodes[0])

        manager.addCustomNode(name: "Home Again", url: home, login: "bob", password: "s3cret")

        // Else the launch migration would let the old login win.
        let kit = NodeCredentialStore.load(isTestnet: false, keychain: fake.keychain)
        XCTAssertEqual(kit.login, "bob")
        XCTAssertEqual(kit.password, "s3cret")
    }

    func testOlderBuildsLoginEditOfTheSelectedNodeWinsAfterUpgrade() throws {
        addHome()
        manager.selectNode(manager.customNodes[0])
        // After a downgrade, an earlier build edits the selected node's login.
        // It writes the new login to the list and to the selected-node login.
        // The item keeps the old login.
        let legacy = [LegacyNode(name: "Home", url: home, login: "alice", password: "changed")]
        UserDefaults.standard.set(try JSONEncoder().encode(legacy), forKey: "customNodes")
        NodeCredentialStore.save(login: "alice", password: "changed", isTestnet: false, keychain: fake.keychain)

        // The upgrade: the launch migration runs, then the list loads.
        let upgraded = NodeManager(keychain: fake.keychain)

        let changed = NodeCredentials(login: "alice", password: "changed")
        XCTAssertEqual(item(home), changed)
        let kit = NodeCredentialStore.load(isTestnet: false, keychain: fake.keychain)
        XCTAssertEqual(NodeCredentials(login: kit.login, password: kit.password), changed)
        XCTAssertEqual(upgraded.customNodes.map(\.credentials), [changed])
        XCTAssertFalse(storedList.contains("changed"))
        XCTAssertFalse(storedList.contains("hunter2"))
    }

    func testSelectingNodeGivesKitItsLogin() {
        addHome()

        manager.selectNode(manager.customNodes[0])

        // The wallet reads this pair when it starts (MoneroWallet.defaultNode).
        let kit = NodeCredentialStore.load(isTestnet: false, keychain: fake.keychain)
        XCTAssertEqual(kit.login, "alice")
        XCTAssertEqual(kit.password, "hunter2")
    }

    // MARK: needsReconnect against the Keychain copy

    func testSelectedNodeRenameKeepsConnection() {
        addHome()
        manager.selectNode(manager.customNodes[0])

        let renamed = MoneroNode(name: "Basement", url: home, login: "alice", password: "hunter2")

        XCTAssertFalse(manager.needsReconnect(editing: manager.customNodes[0], to: renamed))
    }

    func testSelectedNodeLoginChangeReconnects() {
        addHome()
        manager.selectNode(manager.customNodes[0])

        let changed = MoneroNode(name: "Home", url: home, login: "alice", password: "changed")

        XCTAssertTrue(manager.needsReconnect(editing: manager.customNodes[0], to: changed))
    }

    func testSelectedNodeMissingKitLoginReconnects() {
        // A phone restored from a backup: the node shows its login, but the
        // login the kit reads at start is gone. Saving it again must reconnect.
        addHome()
        manager.selectNode(manager.customNodes[0])
        NodeCredentialStore.clear(isTestnet: false, keychain: fake.keychain)

        let unchanged = MoneroNode(name: "Home", url: home, login: "alice", password: "hunter2")

        XCTAssertTrue(manager.needsReconnect(editing: manager.customNodes[0], to: unchanged))
    }

    func testUnselectedNodeComparesWithItsItem() {
        addHome()
        let node = manager.customNodes[0]
        XCTAssertNotEqual(manager.selectedNode.id, node.id)

        let renamed = MoneroNode(name: "Basement", url: home, login: "alice", password: "hunter2")
        let changed = MoneroNode(name: "Home", url: home, login: "alice", password: "changed")

        XCTAssertFalse(manager.needsReconnect(editing: node, to: renamed))
        XCTAssertTrue(manager.needsReconnect(editing: node, to: changed))
    }
}

// MARK: - Duplicate URLs

@MainActor
final class NodeDuplicateURLTests: XCTestCase {

    private var fake: FakeNodeKeychain!
    private let home = "https://home.node:18089"
    private let lab = "http://lab.node:18081"
    private let keys = ["selectedNodeURL", "customNodes", "isTestnet"]
    private var savedSettings: SavedNodeSettings!

    override func setUp() async throws {
        savedSettings = SavedNodeSettings()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        fake = FakeNodeKeychain()
    }

    override func tearDown() async throws {
        fake = nil
        savedSettings.restore()
    }

    private func storeList(_ nodes: [LegacyNode]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(nodes), forKey: "customNodes")
    }

    private func storedEntries() throws -> [[String: Any]] {
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "customNodes"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testNormalizedURL() {
        XCTAssertEqual(NodeManager.normalizedURL("  HTTPS://Node.Example.COM:18089/ \n"), "https://node.example.com:18089")
        XCTAssertEqual(NodeManager.normalizedURL("http://node.example.com:18081//"), "http://node.example.com:18081")
        XCTAssertEqual(NodeManager.normalizedURL("http://Alice:PW@Node.Example.com:18081"), "http://Alice:PW@node.example.com:18081")
        XCTAssertEqual(NodeManager.normalizedURL("http://node.example.com:18081/RPC"), "http://node.example.com:18081/RPC")
        XCTAssertEqual(NodeManager.normalizedURL("Node.Example.com:18081"), "node.example.com:18081")
        // Another scheme or port is another node.
        XCTAssertNotEqual(NodeManager.normalizedURL("http://node.example.com:443"), NodeManager.normalizedURL("https://node.example.com:443"))
        XCTAssertNotEqual(NodeManager.normalizedURL("http://node.example.com:18081"), NodeManager.normalizedURL("http://node.example.com:18089"))
    }

    func testListedURLsHoldEveryListedNode() {
        let manager = NodeManager(keychain: fake.keychain)
        manager.addCustomNode(name: "Home", url: home)

        let listed = manager.listedURLs()

        for node in NodeManager.defaultNodes + NodeManager.torNodes {
            XCTAssertTrue(listed.contains(NodeManager.normalizedURL(node.url)), node.url)
        }
        XCTAssertTrue(listed.contains(NodeManager.normalizedURL("https://HOME.node:18089/")), "A URL in another case is listed")
        XCTAssertFalse(listed.contains(NodeManager.normalizedURL(lab)))
    }

    func testListedURLsLeaveOutTheEditedNode() {
        let manager = NodeManager(keychain: fake.keychain)
        manager.addCustomNode(name: "Home", url: home)
        manager.addCustomNode(name: "Lab", url: lab)

        let listed = manager.listedURLs(except: home)

        XCTAssertFalse(listed.contains(NodeManager.normalizedURL(home)), "The edited node can keep its own URL")
        XCTAssertTrue(listed.contains(NodeManager.normalizedURL(lab)), "Another node's URL is still taken")
        XCTAssertTrue(listed.contains(NodeManager.normalizedURL(NodeManager.defaultNodes[0].url)))
    }

    func testStoredCopiesOfAURLLoadAsOneNode() throws {
        // Earlier builds let the same URL be added twice. The second copy's
        // login still waits in the list.
        try storeList([
            LegacyNode(name: "Home", url: home),
            LegacyNode(name: "Lab", url: lab),
            LegacyNode(name: "Home Again", url: home, login: "alice", password: "hunter2"),
        ])
        fake.failingAccounts = [NodeCredentialStore.nodeAccount(url: home, isTestnet: false)]
        UserDefaults.standard.set(home, forKey: "selectedNodeURL")

        let manager = NodeManager(keychain: fake.keychain)

        XCTAssertEqual(manager.customNodes.map(\.url), [home, lab])
        XCTAssertEqual(manager.customNodes.map(\.name), ["Home", "Lab"], "The first copy keeps its name and place")
        XCTAssertEqual(manager.customNodes[0].credentials, NodeCredentials(login: "alice", password: "hunter2"),
                       "The login of the dropped copy stays")
        let entries = try storedEntries()
        XCTAssertEqual(entries.compactMap { $0["url"] as? String }, [home, lab], "The list is saved without the copy")
        XCTAssertEqual(entries[0]["password"] as? String, "hunter2", "The login keeps waiting for its Keychain write")
        XCTAssertEqual(manager.selectedNode.url, home)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedNodeURL"), home, "The selection stays")
    }

    func testListWithoutCopiesIsNotSavedAgain() throws {
        try storeList([LegacyNode(name: "Home", url: home), LegacyNode(name: "Lab", url: lab)])
        let before = try XCTUnwrap(UserDefaults.standard.data(forKey: "customNodes"))

        _ = NodeManager(keychain: fake.keychain)

        XCTAssertEqual(UserDefaults.standard.data(forKey: "customNodes"), before)
    }

    func testAutoSelectSkipsANodeThatTurnsDownItsLogin() {
        // Set before the manager loads it, so no deferred auto-select runs.
        UserDefaults.standard.set(true, forKey: "autoSelectNode")
        let manager = NodeManager(keychain: fake.keychain)
        manager.addCustomNode(name: "Home", url: home, login: "alice", password: "wrong")
        let hashvault = NodeManager.defaultNodes[1].url
        manager.nodeStats = [
            home: NodeStats(uptimeMonth: 100, uptimeYear: 100, isUp: true, latencyMs: 1, authFailed: true),
            hashvault: NodeStats(uptimeMonth: 99, uptimeYear: 99, isUp: true, latencyMs: 80),
        ]

        manager.selectBestNode()

        XCTAssertEqual(manager.selectedNode.url, hashvault)
    }
}

// MARK: - Restart on a node change

/// A wallet with no wallet2 behind it. Its stop can be held open, as a dead
/// node holds a real stop open. It counts the pauses that do not wait, and
/// logs the pause that waits.
@MainActor
private final class SpyWallet: MoneroWallet {
    var stopGate: Gate?
    var log: @MainActor (String) -> Void = { _ in }
    private(set) var pauseCount = 0

    override func stopAsync() async {
        log("stop")
        await stopGate?.wait()
        log("stopped")
    }

    override func pauseSync() {
        pauseCount += 1
    }

    override func pauseSyncAsync() async {
        log("paused")
    }
}

/// The order of the steps a test watches.
@MainActor
private final class EventLog {
    private(set) var items: [String] = []

    func add(_ item: String) {
        items.append(item)
    }
}

/// Holds each waiter until it opens.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// A node, login or proxy change restarts the wallet for every wallet type.
@MainActor
final class NodeChangeRestartTests: XCTestCase {

    private let seed = ["abandon", "ability", "able", "about"]
    private let pin = "123456"
    private let trezor = WalletSource.hardware(.trezor(TrezorBinding(model: "Safe 7", deviceId: "T1")))
    private var savedSettings: SavedNodeSettings!

    override func setUp() async throws {
        savedSettings = SavedNodeSettings()
        ["selectedNodeURL", "customNodes", "isTestnet"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() async throws {
        savedSettings.restore()
    }

    private func wallet(_ source: WalletSource) -> WalletInfo {
        WalletInfo(id: UUID(), name: "Wallet", source: source, createdAt: Date(), restoreHeight: 0, syncResetCount: 0,
                   userCreatedSubaddressIndices: [], cachedPrimaryAddress: nil, cachedBalance: nil)
    }

    private func restartKeys(
        for wallet: WalletInfo?,
        isUnlocked: Bool = true,
        seed: [String]? = nil,
        pin: String? = "123456",
        session: WalletManager.HardwareSessionState = .idle,
        switching: Bool = false
    ) -> WalletManager.RestartKeys? {
        WalletManager.restartKeys(for: wallet, isUnlocked: isUnlocked, currentSeed: seed, currentPin: pin,
                                  hardwareSession: session, isSwitchingWallet: switching)
    }

    /// A manager that ran one restart, so `first` is its open wallet. No
    /// wallet2 runs, and the node is a closed local port.
    private func managerRunning(_ info: WalletInfo, keys: WalletManager.RestartKeys) async -> (WalletManager, SpyWallet) {
        UserDefaults.standard.set("http://localhost:1", forKey: "selectedNodeURL")
        let manager = WalletManager()
        manager.activeWallet = info
        manager.isUnlocked = true
        let first = SpyWallet()
        manager.openRestartedWalletForTesting = { _ in first }
        XCTAssertTrue(manager.restartActiveWallet(with: keys))
        await manager.restartTask?.value
        XCTAssertTrue(manager.moneroWallet === first)
        XCTAssertEqual(first.pauseCount, 0, "Sync runs when nothing paused it")
        return (manager, first)
    }

    func testEveryWalletTypeRestarts() {
        let seeded = wallet(.seed(.polyseed))
        let viewOnly = wallet(.viewOnly)
        let hardware = wallet(trezor)

        XCTAssertEqual(restartKeys(for: seeded, seed: seed), .seed(seed))
        XCTAssertEqual(restartKeys(for: viewOnly), .viewKeys(walletId: viewOnly.id, pin: pin))
        XCTAssertEqual(restartKeys(for: hardware), .viewKeys(walletId: hardware.id, pin: pin),
                       "A Trezor wallet opens watch-only from its view keys, without the device")
    }

    func testAViewOnlyWalletDoesNotRestartFromALeftoverSeed() {
        let viewOnly = wallet(.viewOnly)

        XCTAssertEqual(restartKeys(for: viewOnly, seed: seed), .viewKeys(walletId: viewOnly.id, pin: pin))
    }

    func testNoRestartWithoutTheSecret() {
        XCTAssertNil(restartKeys(for: wallet(.seed(.bip39)), seed: nil))
        XCTAssertNil(restartKeys(for: wallet(.viewOnly), pin: nil))
        XCTAssertNil(restartKeys(for: wallet(trezor), pin: nil))
    }

    func testNoRestartWhileLocked() {
        XCTAssertNil(restartKeys(for: wallet(.seed(.legacy)), isUnlocked: false, seed: seed))
        XCTAssertNil(restartKeys(for: wallet(.viewOnly), isUnlocked: false))
        XCTAssertNil(restartKeys(for: wallet(trezor), isUnlocked: false))
        XCTAssertNil(restartKeys(for: nil))
    }

    func testNoRestartWhileATrezorSessionHoldsTheWallet() {
        let hardware = wallet(trezor)
        let running: [WalletManager.HardwareSessionState] = [
            .connecting, .openingFull, .syncingFull(progress: 0.5, blocksRemaining: 10),
            .syncingKeyImages, .signing, .broadcasting, .tearingDown,
        ]
        let ended: [WalletManager.HardwareSessionState] = [.idle, .complete(message: "Done"), .failed(message: "Failed")]

        for state in running {
            XCTAssertNil(restartKeys(for: hardware, session: state), "\(state)")
        }
        for state in ended {
            XCTAssertEqual(restartKeys(for: hardware, session: state), .viewKeys(walletId: hardware.id, pin: pin), "\(state)")
        }
    }

    func testNoRestartWhileAWalletSwitchRuns() {
        // A change during a switch waits until the switch ends.
        XCTAssertNil(restartKeys(for: wallet(.viewOnly), switching: true))
        XCTAssertNil(restartKeys(for: wallet(.seed(.polyseed)), seed: seed, switching: true))
        XCTAssertNil(restartKeys(for: wallet(trezor), switching: true))
    }

    func testASwitchWaitsForASlowRestartStop() async throws {
        let info = wallet(.viewOnly)
        let (manager, old) = await managerRunning(info, keys: .viewKeys(walletId: info.id, pin: pin))
        let events = EventLog()
        let stop = Gate()
        old.stopGate = stop
        old.log = events.add
        manager.openRestartedWalletForTesting = { _ in events.add("open"); return SpyWallet() }

        XCTAssertTrue(manager.restartActiveWallet(with: .viewKeys(walletId: info.id, pin: pin)))
        // Without a PIN in memory the switch throws before it opens a wallet.
        let switching = Task {
            try? await manager.completeSwitchToWallet(target: self.wallet(.viewOnly))
            events.add("switch done")
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(events.items, ["stop"], "The switch waits while the old wallet stops")

        stop.open()
        await switching.value

        XCTAssertEqual(events.items, ["stop", "stopped", "switch done"], "The cancelled restart opens no wallet")
        XCTAssertNil(manager.moneroWallet)
    }

    func testALockDuringASlowRestartStopOpensNoWallet() async {
        let info = wallet(.seed(.polyseed))
        let (manager, old) = await managerRunning(info, keys: .seed(seed))
        let events = EventLog()
        let stop = Gate()
        old.stopGate = stop
        old.log = events.add
        manager.openRestartedWalletForTesting = { _ in events.add("open"); return SpyWallet() }

        XCTAssertTrue(manager.restartActiveWallet(with: .seed(seed)))
        manager.lock()
        // An unlock comes in while the old wallet still stops.
        manager.isUnlocked = true
        stop.open()
        await manager.restartTask?.value

        XCTAssertEqual(events.items, ["stop", "stopped"], "The restart opens no wallet after a lock")
        XCTAssertNil(manager.moneroWallet)
    }

    func testABackgroundPauseDuringASlowRestartWaitsUntilTheNewWalletPauses() async throws {
        let info = wallet(trezor)
        let (manager, old) = await managerRunning(info, keys: .viewKeys(walletId: info.id, pin: pin))
        let events = EventLog()
        let stop = Gate()
        old.stopGate = stop
        old.log = events.add
        let new = SpyWallet()
        new.log = events.add
        manager.openRestartedWalletForTesting = { _ in events.add("open"); return new }

        XCTAssertTrue(manager.restartActiveWallet(with: .viewKeys(walletId: info.id, pin: pin)))
        // The app goes to the background while the old wallet still stops.
        let background = Task {
            await manager.pauseSyncAsync()
            events.add("pause done")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(events.items, ["stop"], "The pause waits for the restart")

        stop.open()
        await background.value

        XCTAssertEqual(events.items, ["stop", "stopped", "open", "paused", "pause done"],
                       "The new wallet has paused before iOS can suspend the app")
        XCTAssertTrue(manager.moneroWallet === new)
        XCTAssertEqual(new.pauseCount, 1, "The restart pauses the new wallet too")
    }

    func testAReturnToTheForegroundDuringASlowRestartLeavesTheNewWalletSyncing() async throws {
        let info = wallet(.viewOnly)
        let (manager, old) = await managerRunning(info, keys: .viewKeys(walletId: info.id, pin: pin))
        let events = EventLog()
        let stop = Gate()
        old.stopGate = stop
        old.log = events.add
        let new = SpyWallet()
        new.log = events.add
        manager.openRestartedWalletForTesting = { _ in events.add("open"); return new }

        XCTAssertTrue(manager.restartActiveWallet(with: .viewKeys(walletId: info.id, pin: pin)))
        let background = Task {
            await manager.pauseSyncAsync()
            events.add("pause done")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        // The app comes back before the old wallet has stopped.
        manager.resumeSync()
        stop.open()
        await background.value

        XCTAssertEqual(events.items, ["stop", "stopped", "open", "pause done"], "Nothing pauses the new wallet")
        XCTAssertTrue(manager.moneroWallet === new)
        XCTAssertEqual(new.pauseCount, 0)
    }

    func testANodeChangeDuringASwitchRestartsTheWalletWhenTheSwitchEnds() async {
        let activeIdKey = "one.monero.walletStore.activeWalletId"
        let savedActiveId = UserDefaults.standard.string(forKey: activeIdKey)
        let savedLogin = NodeCredentialStore.load(isTestnet: false)
        defer {
            UserDefaults.standard.set(savedActiveId, forKey: activeIdKey)
            NodeCredentialStore.save(login: savedLogin.login, password: savedLogin.password, isTestnet: false)
        }
        let info = wallet(.viewOnly)
        let target = wallet(.viewOnly)
        let (manager, _) = await managerRunning(info, keys: .viewKeys(walletId: info.id, pin: pin))
        manager.setCurrentPinForTesting(pin)
        manager.wallets = [info, target]
        let opened = EventLog()
        let new = SpyWallet()
        manager.openRestartedWalletForTesting = { keys in
            if case .viewKeys(let id, _) = keys { opened.add(id.uuidString) }
            return new
        }

        XCTAssertNotNil(manager.prepareSwitchToWallet(id: target.id))
        let restartBeforeTheChange = manager.restartTask
        let switching = Task { try await manager.completeSwitchToWallet(target: target) }
        // The node changes while the switch runs.
        manager.setNode(url: "http://localhost:2")
        XCTAssertTrue(manager.restartTask == restartBeforeTheChange, "No restart runs during the switch")

        // A cancel ends the switch before it reads the Keychain, which this
        // test does not use.
        switching.cancel()
        _ = await switching.result
        XCTAssertFalse(manager.isSwitchingWallet)
        XCTAssertFalse(manager.restartTask == restartBeforeTheChange, "The switch ends with a restart")
        await manager.restartTask?.value

        XCTAssertEqual(opened.items, [target.id.uuidString], "One restart opens the wallet the switch went to")
        XCTAssertTrue(manager.moneroWallet === new)
    }

    func testAutoSelectSendsTheNodeItSwitchesTo() {
        // Set before the manager loads it, so no deferred auto-select runs.
        UserDefaults.standard.set(true, forKey: "autoSelectNode")
        let manager = NodeManager(keychain: FakeNodeKeychain().keychain)
        let moneroOne = NodeManager.defaultNodes[0].url
        let hashvault = NodeManager.defaultNodes[1].url
        manager.selectNode(NodeManager.defaultNodes[0])
        manager.nodeStats = [
            moneroOne: NodeStats(uptimeMonth: 100, uptimeYear: 100, isUp: true, latencyMs: 400),
            hashvault: NodeStats(uptimeMonth: 100, uptimeYear: 100, isUp: true, latencyMs: 20),
        ]
        var sent: [String] = []
        let subscription = manager.autoSelectedNode.sink { sent.append($0.url) }
        defer { subscription.cancel() }

        manager.selectBestNode()
        manager.selectBestNode()

        XCTAssertEqual(manager.selectedNode.url, hashvault)
        XCTAssertEqual(sent, [hashvault], "Sent once, on the switch")
    }

    func testAutoSelectSendsNothingWithoutASwitch() {
        UserDefaults.standard.set(true, forKey: "autoSelectNode")
        let manager = NodeManager(keychain: FakeNodeKeychain().keychain)
        let moneroOne = NodeManager.defaultNodes[0].url
        manager.selectNode(NodeManager.defaultNodes[0])
        manager.nodeStats = [moneroOne: NodeStats(uptimeMonth: 100, uptimeYear: 100, isUp: true, latencyMs: 20)]
        var sent: [String] = []
        let subscription = manager.autoSelectedNode.sink { sent.append($0.url) }
        defer { subscription.cancel() }

        manager.selectBestNode()
        manager.autoSelectEnabled = false
        manager.nodeStats[NodeManager.defaultNodes[1].url] = NodeStats(uptimeMonth: 100, uptimeYear: 100, isUp: true, latencyMs: 1)
        manager.selectBestNode()

        XCTAssertEqual(manager.selectedNode.url, moneroOne)
        XCTAssertEqual(sent, [], "Nothing is sent while the best node is selected or auto-select is off")
    }
}

// MARK: - Lock during a wallet open

/// A lock that comes in while a wallet opens holds: the app stays locked, and
/// the next unlock opens the wallet once. The target wallet keeps its keys in
/// the Keychain under the test PIN. No wallet2 runs.
@MainActor
final class LockDuringOpenTests: XCTestCase {

    private let pin = "123456"
    private let activeIdKey = "one.monero.walletStore.activeWalletId"
    private let keychain = KeychainStorage()
    private let trezor = WalletSource.hardware(.trezor(TrezorBinding(model: "Safe 7", deviceId: "T1")))
    private var savedSettings: SavedNodeSettings!
    private var savedActiveId: String?
    private var keychainWalletIds: [UUID] = []

    override func setUp() async throws {
        savedSettings = SavedNodeSettings()
        savedActiveId = UserDefaults.standard.string(forKey: activeIdKey)
        ["selectedNodeURL", "customNodes", "isTestnet"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set("http://localhost:1", forKey: "selectedNodeURL")
    }

    override func tearDown() async throws {
        for id in keychainWalletIds {
            keychain.deleteViewOnly(walletId: id)
            keychain.deleteSeed(walletId: id)
        }
        UserDefaults.standard.set(savedActiveId, forKey: activeIdKey)
        savedSettings.restore()
    }

    private func wallet(_ source: WalletSource, name: String) -> WalletInfo {
        WalletInfo(id: UUID(), name: name, source: source, createdAt: Date(), restoreHeight: 0, syncResetCount: 0,
                   userCreatedSubaddressIndices: [], cachedPrimaryAddress: nil, cachedBalance: nil)
    }

    /// A wallet whose keys are in the Keychain under the test PIN.
    private func walletInTheKeychain(_ source: WalletSource) throws -> WalletInfo {
        let info = wallet(source, name: "Target")
        keychainWalletIds.append(info.id)
        switch source {
        case .seed:
            try keychain.saveSeed("target seed words", pin: pin, walletId: info.id)
        case .viewOnly, .hardware:
            try keychain.saveViewOnly(address: "target address", viewKey: "target view key", pin: pin, walletId: info.id)
        }
        return info
    }

    /// An unlocked manager. Its wallet `running` is open on `from`.
    private func managerRunning(_ from: WalletInfo, wallets: [WalletInfo]) async -> (WalletManager, SpyWallet) {
        let manager = WalletManager()
        manager.wallets = wallets
        manager.activeWallet = from
        manager.isUnlocked = true
        manager.setCurrentPinForTesting(pin)
        let running = SpyWallet()
        manager.openRestartedWalletForTesting = { _ in running }
        XCTAssertTrue(manager.restartActiveWallet(with: .viewKeys(walletId: from.id, pin: pin)))
        await manager.restartTask?.value
        XCTAssertTrue(manager.moneroWallet === running)
        return (manager, running)
    }

    func testALockDuringASwitchToASeedWalletHolds() async throws {
        try await checkALockDuringASwitch(to: .seed(.polyseed))
    }

    func testALockDuringASwitchToAViewOnlyWalletHolds() async throws {
        try await checkALockDuringASwitch(to: .viewOnly)
    }

    func testALockDuringASwitchToATrezorWatchOnlyWalletHolds() async throws {
        try await checkALockDuringASwitch(to: trezor)
    }

    /// The app locks while a switch opens the target wallet. The wallet that
    /// opened stops before it shows, the app stays locked, and the next
    /// unlock opens the target wallet.
    private func checkALockDuringASwitch(to source: WalletSource) async throws {
        let from = wallet(.viewOnly, name: "From")
        let target = try walletInTheKeychain(source)
        let (manager, _) = await managerRunning(from, wallets: [from, target])
        let events = EventLog()
        let opening = Gate()
        let openEnds = Gate()
        let first = SpyWallet()
        first.log = { events.add("first \($0)") }
        let second = SpyWallet()
        manager.openWalletForTesting = { id in
            XCTAssertEqual(id, target.id)
            events.add("open")
            guard events.items.filter({ $0 == "open" }).count == 1 else { return second }
            opening.open()
            await openEnds.wait()
            return first
        }

        XCTAssertNotNil(manager.prepareSwitchToWallet(id: target.id))
        let switching = Task { try await manager.completeSwitchToWallet(target: target) }
        await opening.wait()
        manager.lock()
        openEnds.open()

        let result = await switching.result
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? WalletError, .notUnlocked) }
        XCTAssertEqual(events.items, ["open", "first stop", "first stopped"], "The wallet that opened stops")
        XCTAssertFalse(manager.isUnlocked, "The app stays locked")
        XCTAssertNil(manager.moneroWallet, "The wallet that opened does not show")

        try await manager.unlock(pin: pin)

        XCTAssertEqual(events.items, ["open", "first stop", "first stopped", "open"])
        XCTAssertTrue(manager.isUnlocked)
        XCTAssertTrue(manager.moneroWallet === second, "The unlock opens the target wallet")
        XCTAssertEqual(manager.activeWallet?.id, target.id)
    }

    /// The PIN comes in while the wallet that opened after the lock still
    /// stops. The unlock waits for that stop, so two opens of one wallet never
    /// run at the same time.
    func testAnUnlockWaitsUntilTheWalletThatTheLockStoppedHasStopped() async throws {
        let from = wallet(.viewOnly, name: "From")
        let target = try walletInTheKeychain(.seed(.polyseed))
        let (manager, _) = await managerRunning(from, wallets: [from, target])
        let events = EventLog()
        let opening = Gate()
        let openEnds = Gate()
        let stopEnds = Gate()
        let first = SpyWallet()
        first.stopGate = stopEnds
        first.log = { events.add("first \($0)") }
        let second = SpyWallet()
        manager.openWalletForTesting = { _ in
            events.add("open")
            guard events.items.filter({ $0 == "open" }).count == 1 else { return second }
            opening.open()
            await openEnds.wait()
            return first
        }

        XCTAssertNotNil(manager.prepareSwitchToWallet(id: target.id))
        let switching = Task { try? await manager.completeSwitchToWallet(target: target) }
        await opening.wait()
        manager.lock()
        let unlocking = Task { try await manager.unlock(pin: self.pin) }
        openEnds.open()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(events.items, ["open", "first stop"], "The unlock waits while the first wallet stops")
        XCTAssertFalse(manager.isUnlocked)

        stopEnds.open()
        _ = await switching.value
        try await unlocking.value

        XCTAssertEqual(events.items, ["open", "first stop", "first stopped", "open"])
        XCTAssertTrue(manager.isUnlocked)
        XCTAssertTrue(manager.moneroWallet === second)
    }

    /// The app locks while a switch stops the old wallet, and the PIN comes in
    /// before that stop ends. The unlock opens the target wallet, and the
    /// switch then opens no second wallet.
    func testAPINDuringASwitchStopOpensTheTargetWalletOnce() async throws {
        let from = wallet(.viewOnly, name: "From")
        let target = try walletInTheKeychain(.seed(.polyseed))
        let (manager, old) = await managerRunning(from, wallets: [from, target])
        let events = EventLog()
        let stopping = Gate()
        let stopEnds = Gate()
        old.stopGate = stopEnds
        old.log = { item in
            events.add("old \(item)")
            if item == "stop" { stopping.open() }
        }
        let opened = SpyWallet()
        manager.openWalletForTesting = { id in
            XCTAssertEqual(id, target.id)
            events.add("open")
            return opened
        }

        XCTAssertNotNil(manager.prepareSwitchToWallet(id: target.id))
        let switching = Task { try await manager.completeSwitchToWallet(target: target) }
        await stopping.wait()
        manager.lock()
        try await manager.unlock(pin: pin)
        XCTAssertTrue(manager.moneroWallet === opened, "The unlock opens the target wallet")

        stopEnds.open()
        let result = await switching.result
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? WalletError, .notUnlocked) }
        XCTAssertEqual(events.items, ["old stop", "open", "old stopped"], "The switch opens no second wallet")
        XCTAssertTrue(manager.isUnlocked)
        XCTAssertTrue(manager.moneroWallet === opened)
    }
}

// MARK: - State on a wallet switch

/// A wallet switch shows only the next wallet's history, balance and receive
/// address, at no moment the previous wallet's. No wallet2 runs.
@MainActor
final class SwitchHistoryTests: XCTestCase {

    private let pin = "123456"
    private let activeIdKey = "one.monero.walletStore.activeWalletId"
    private let keychain = KeychainStorage()
    private var savedSettings: SavedNodeSettings!
    private var savedActiveId: String?
    private var keychainWalletIds: [UUID] = []

    override func setUp() async throws {
        savedSettings = SavedNodeSettings()
        savedActiveId = UserDefaults.standard.string(forKey: activeIdKey)
        ["selectedNodeURL", "customNodes", "isTestnet"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set("http://localhost:1", forKey: "selectedNodeURL")
    }

    override func tearDown() async throws {
        for id in keychainWalletIds {
            keychain.deleteSeed(walletId: id)
        }
        UserDefaults.standard.set(savedActiveId, forKey: activeIdKey)
        savedSettings.restore()
    }

    private func wallet(_ source: WalletSource, name: String) -> WalletInfo {
        WalletInfo(id: UUID(), name: name, source: source, createdAt: Date(), restoreHeight: 0, syncResetCount: 0,
                   userCreatedSubaddressIndices: [], cachedPrimaryAddress: nil, cachedBalance: nil)
    }

    private func row(_ id: String) -> MoneroTransaction {
        MoneroTransaction(id: id, type: .incoming, amount: 1, fee: 0, address: "", timestamp: Date(),
                          confirmations: 20, status: .confirmed, memo: nil, blockHeight: 3_000_000)
    }

    /// Lets the main queue run what it holds, as `receive(on:)` sends there.
    private func mainQueueDrained() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    /// An unlocked manager with `running` open on the wallet "From", and a
    /// target wallet whose seed is in the Keychain under the test PIN.
    private func managerRunning(_ running: SpyWallet) async throws -> (WalletManager, WalletInfo) {
        let from = wallet(.viewOnly, name: "From")
        let target = wallet(.seed(.polyseed), name: "Target")
        keychainWalletIds.append(target.id)
        try keychain.saveSeed("target seed words", pin: pin, walletId: target.id)

        let manager = WalletManager()
        manager.wallets = [from, target]
        manager.activeWallet = from
        manager.isUnlocked = true
        manager.setCurrentPinForTesting(pin)
        manager.openRestartedWalletForTesting = { _ in running }
        XCTAssertTrue(manager.restartActiveWallet(with: .viewKeys(walletId: from.id, pin: pin)))
        await manager.restartTask?.value
        await mainQueueDrained()
        return (manager, target)
    }

    func testASwitchShowsOnlyTheNextWalletsRows() async throws {
        let running = SpyWallet()
        running.transactions = [row("from-1")]
        let (manager, target) = try await managerRunning(running)
        XCTAssertEqual(manager.transactions.map(\.id), ["from-1"])

        // The next wallet opens with its stored rows.
        let opened = SpyWallet()
        opened.transactions = [row("target-1")]
        manager.openWalletForTesting = { id in
            XCTAssertEqual(id, target.id)
            return opened
        }

        XCTAssertNotNil(manager.prepareSwitchToWallet(id: target.id))
        let shown = EventLog()
        let watch = manager.$transactions.sink { rows in shown.add(rows.map(\.id).joined(separator: ",")) }
        // A refresh of the previous wallet lands after the switch began.
        running.transactions = [row("from-2"), row("from-1")]
        await mainQueueDrained()
        XCTAssertEqual(manager.transactions, [], "The previous wallet's rows stay off")

        try await manager.completeSwitchToWallet(target: target)
        await mainQueueDrained()
        watch.cancel()

        XCTAssertTrue(manager.moneroWallet === opened)
        XCTAssertEqual(manager.transactions.map(\.id), ["target-1"], "The list holds only the next wallet's rows")
        XCTAssertFalse(shown.items.contains { $0.contains("from") }, "No previous wallet row showed: \(shown.items)")
    }

    func testASwitchShowsOnlyTheNextWalletsBalanceAndAddress() async throws {
        let running = SpyWallet()
        running.balance = 5
        running.unlockedBalance = 5
        running.address = "from-address-1"
        let (manager, target) = try await managerRunning(running)
        XCTAssertEqual(manager.balance, 5)
        XCTAssertEqual(manager.address, "from-address-1")

        // The next wallet opens with its stored balance and receive address.
        let opened = SpyWallet()
        opened.balance = 3
        opened.unlockedBalance = 2
        opened.address = "target-address"
        manager.openWalletForTesting = { _ in opened }

        XCTAssertNotNil(manager.prepareSwitchToWallet(id: target.id))
        let shown = EventLog()
        let watches = [
            manager.$balance.sink { shown.add("balance \($0)") },
            manager.$unlockedBalance.sink { shown.add("unlocked \($0)") },
            manager.$address.sink { shown.add("address \($0)") },
        ]
        // A refresh of the previous wallet lands after the switch began.
        running.balance = 7
        running.unlockedBalance = 7
        running.address = "from-address-2"
        await mainQueueDrained()
        XCTAssertEqual(manager.balance, 0, "The next wallet has no cached balance yet")
        XCTAssertEqual(manager.address, "")

        try await manager.completeSwitchToWallet(target: target)
        await mainQueueDrained()
        watches.forEach { $0.cancel() }

        XCTAssertTrue(manager.moneroWallet === opened)
        XCTAssertEqual(manager.balance, 3)
        XCTAssertEqual(manager.unlockedBalance, 2)
        XCTAssertEqual(manager.address, "target-address")
        // The switch leaves the unlocked balance as it was until the next
        // wallet binds, so only the late value counts there.
        let previous = shown.items.filter { ["balance 5", "balance 7", "unlocked 7"].contains($0) || $0.contains("from") }
        XCTAssertEqual(previous, [], "No previous wallet value showed: \(shown.items)")
    }
}

// MARK: - Digest Auth

final class HTTPDigestTests: XCTestCase {

    // RFC 2617 section 3.5 worked example.
    private let rfcChallenge = "Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", "
        + "nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""

    private func response(in header: String) -> String? {
        HTTPDigest.parameters(of: header)?["response"]
    }

    func testRFC2617Example() throws {
        let header = try XCTUnwrap(HTTPDigest.authorization(
            challenge: rfcChallenge, method: "GET", uri: "/dir/index.html",
            credentials: NodeCredentials(login: "Mufasa", password: "Circle Of Life"),
            cnonce: "0a4f113b", nonceCount: 1
        ))

        XCTAssertTrue(header.hasPrefix("Digest username=\"Mufasa\""))
        for part in ["response=\"6629fae49393a05397450978507c4ef1\"", "realm=\"testrealm@host.com\"",
                     "nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\"", "uri=\"/dir/index.html\"", "qop=auth",
                     "nc=00000001", "cnonce=\"0a4f113b\"", "opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"",
                     "algorithm=MD5"] {
            XCTAssertTrue(header.contains(part), part)
        }
    }

    func testMonerodChallenge() throws {
        // The shape epee sends for --rpc-login.
        let challenge = "Digest qop=\"auth\",algorithm=MD5,realm=\"monero-rpc\",nonce=\"AbCd\",stale=false"
        let parameters = try XCTUnwrap(HTTPDigest.parameters(of: challenge))
        XCTAssertEqual(parameters, ["qop": "auth", "algorithm": "MD5", "realm": "monero-rpc", "nonce": "AbCd", "stale": "false"])

        let header = try XCTUnwrap(HTTPDigest.authorization(
            challenge: challenge, method: "GET", uri: "/get_info",
            credentials: NodeCredentials(login: "u", password: "p"), cnonce: "c"
        ))
        XCTAssertTrue(header.contains("realm=\"monero-rpc\""))
        XCTAssertTrue(header.contains("uri=\"/get_info\""))
    }

    func testMD5SessAndNoQopGiveOtherResponses() throws {
        let credentials = NodeCredentials(login: "u", password: "p")
        let plain = try XCTUnwrap(HTTPDigest.authorization(challenge: rfcChallenge, method: "GET", uri: "/x",
                                                           credentials: credentials, cnonce: "c"))
        let sess = try XCTUnwrap(HTTPDigest.authorization(
            challenge: rfcChallenge.replacingOccurrences(of: "Digest ", with: "Digest algorithm=MD5-sess, "),
            method: "GET", uri: "/x", credentials: credentials, cnonce: "c"))
        let noQop = try XCTUnwrap(HTTPDigest.authorization(challenge: "Digest realm=\"r\", nonce=\"n\"", method: "GET",
                                                           uri: "/x", credentials: credentials, cnonce: "c"))

        let responses = [plain, sess, noQop].compactMap(response(in:))
        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(Set(responses).count, 3)
        XCTAssertTrue(sess.contains("algorithm=MD5-sess"))
        XCTAssertFalse(noQop.contains("qop="))
        XCTAssertFalse(noQop.contains("cnonce="))
    }

    func testUnsupportedChallengesGiveNil() {
        let credentials = NodeCredentials(login: "u", password: "p")
        for challenge in ["Basic realm=\"x\"",
                          "Digest realm=\"x\"",
                          "Digest realm=\"x\", nonce=\"n\", qop=\"auth-int\"",
                          "Digest realm=\"x\", nonce=\"n\", algorithm=SHA-256"] {
            XCTAssertNil(HTTPDigest.authorization(challenge: challenge, method: "GET", uri: "/", credentials: credentials),
                         challenge)
        }
    }

    func testQuotesInValuesAreEscaped() throws {
        let header = try XCTUnwrap(HTTPDigest.authorization(
            challenge: "Digest realm=\"r\\\"q\", nonce=\"n\"", method: "GET", uri: "/",
            credentials: NodeCredentials(login: "a\"b", password: "p")
        ))
        XCTAssertTrue(header.contains("username=\"a\\\"b\""))
        XCTAssertTrue(header.contains("realm=\"r\\\"q\""))
        XCTAssertEqual(HTTPDigest.parameters(of: header)?["username"], "a\"b")
    }
}

// MARK: - Login Check

/// A TCP server on the loopback interface. `reply` reads a session's input,
/// removes what it used and returns the bytes to send: nil waits for more
/// input, and empty data closes the connection.
private final class LoopbackServer: @unchecked Sendable {
    final class Session {
        var input = Data()
        var state: [String: String] = [:]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "one.monero.tests.loopback")
    private let reply: (Session) -> Data?
    private var sessions: [(connection: NWConnection, session: Session)] = []

    init(reply: @escaping (Session) -> Data?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
        self.reply = reply
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var connectionCount: Int { queue.sync { sessions.count } }
    var states: [[String: String]] { queue.sync { sessions.map(\.session.state) } }

    private var started: CheckedContinuation<Void, Never>?

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            started = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready, .failed, .cancelled:
                    self.started?.resume()
                    self.started = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let session = Session()
                self.sessions.append((connection, session))
                connection.start(queue: self.queue)
                self.read(connection, session)
            }
            listener.start(queue: queue)
        }
    }

    private func read(_ connection: NWConnection, _ session: Session) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                session.input.append(data)
            }
            while let out = self.reply(session) {
                if out.isEmpty {
                    connection.cancel()
                    return
                }
                connection.send(content: out, completion: .idempotent)
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, session)
            }
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            sessions.forEach { $0.connection.cancel() }
        }
    }
}

final class NodeLoginProbeTests: XCTestCase {

    private var servers: [LoopbackServer] = []

    override func tearDown() async throws {
        servers.forEach { $0.stop() }
        servers = []
    }

    private func start(_ reply: @escaping (LoopbackServer.Session) -> Data?) async throws -> LoopbackServer {
        let server = try LoopbackServer(reply: reply)
        servers.append(server)
        await server.start()
        XCTAssertNotEqual(server.port, 0)
        return server
    }

    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func httpReply(_ status: String, headers: [String] = [], body: String) -> Data {
        let lines = ["HTTP/1.1 \(status)", "Content-Length: \(Data(body.utf8).count)"] + headers
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    /// A node that asks for a login the way monerod's --rpc-login does. Each
    /// connection has its own nonce, so only an answer on the connection
    /// that got the challenge logs in, and the connection stays open after
    /// a 401.
    private static func monerod(login: String?, password: String?) -> (LoopbackServer.Session) -> Data? {
        { session in
            guard let headEnd = session.input.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: session.input[..<headEnd.lowerBound], as: UTF8.self)
            session.input.removeSubrange(..<headEnd.upperBound)
            session.state["requests", default: ""] += "x"

            let ok = httpReply("200 Ok", headers: ["Content-Type: application/json"], body: "{\"status\":\"OK\"}")
            guard let login, let password else { return ok }

            let nonce = session.state["nonce"] ?? UUID().uuidString
            session.state["nonce"] = nonce
            let answer = head.components(separatedBy: "\r\n").dropFirst()
                .first { $0.lowercased().hasPrefix("authorization:") }
                .flatMap { HTTPDigest.parameters(of: String($0.dropFirst("authorization:".count))) }
            if let answer, answer["nonce"] == nonce, answer["username"] == login,
               let uri = answer["uri"], let nc = answer["nc"], let cnonce = answer["cnonce"], answer["qop"] == "auth" {
                let ha1 = md5("\(login):monero-rpc:\(password)")
                let ha2 = md5("GET:\(uri)")
                if answer["response"] == md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)") {
                    return ok
                }
            }
            let stale = answer != nil && answer?["nonce"] != nonce
            let body = "<html><head><title>Unauthorized Access</title></head><body><h1>401 Unauthorized</h1></body></html>"
            return httpReply("401 Unauthorized", headers: [
                "Server: Epee-based",
                "Content-Type: text/html",
                "WWW-authenticate: Digest qop=\"auth\",algorithm=MD5,realm=\"monero-rpc\",nonce=\"\(nonce)\",stale=\(stale)",
                "WWW-authenticate: Digest qop=\"auth\",algorithm=MD5-sess,realm=\"monero-rpc\",nonce=\"\(nonce)\",stale=\(stale)",
            ], body: body)
        }
    }

    private func check(_ server: LoopbackServer, _ credentials: NodeCredentials, proxy: String = "") async -> NodeLoginCheck {
        await NodeLoginProbe.check(url: "http://localhost:\(server.port)", credentials: credentials, proxy: proxy, timeout: 5)
    }

    func testRightLoginIsAcceptedOnOneConnection() async throws {
        let node = try await start(Self.monerod(login: "kc", password: "right"))

        let result = await check(node, NodeCredentials(login: "kc", password: "right"))

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(node.connectionCount, 1, "The answer to the challenge goes on the same connection")
        XCTAssertEqual(node.states.first?["requests"], "xx")
    }

    func testWrongPasswordIsRejected() async throws {
        let node = try await start(Self.monerod(login: "kc", password: "right"))

        let result = await check(node, NodeCredentials(login: "kc", password: "wrong"))

        XCTAssertEqual(result, .rejected)
    }

    func testNoLoginOnALoginNodeIsRejected() async throws {
        let node = try await start(Self.monerod(login: "kc", password: "right"))

        let result = await check(node, .none)

        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(node.states.first?["requests"], "x", "With no login there is nothing to answer")
    }

    func testNodeWithoutLoginIsAccepted() async throws {
        let node = try await start(Self.monerod(login: nil, password: nil))

        let result = await check(node, NodeCredentials(login: "kc", password: "any"))

        XCTAssertEqual(result, .accepted)
    }

    func testOtherRepliesAreInconclusive() async throws {
        let node = try await start { session in
            guard let headEnd = session.input.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            session.input.removeSubrange(..<headEnd.upperBound)
            return Self.httpReply("403 Forbidden", body: "")
        }

        let result = await check(node, NodeCredentials(login: "kc", password: "right"))

        XCTAssertEqual(result, .inconclusive)
    }

    func testNodeThatIsDownIsInconclusive() async throws {
        let node = try await start { _ in nil }
        let url = "http://localhost:\(node.port)"
        node.stop()

        let result = await NodeLoginProbe.check(url: url, credentials: .none, proxy: "", timeout: 5)

        XCTAssertEqual(result, .inconclusive)
    }

    /// With a proxy, the check asks the proxy for the node and never
    /// connects to the node itself, even when the proxy turns it down.
    /// A SOCKS5 proxy that records the port each client asks for, then
    /// reports that it cannot reach it.
    private static func refusingSocksProxy(_ session: LoopbackServer.Session) -> Data? {
        let bytes = [UInt8](session.input)
        switch session.state["step"] {
        case nil:
            // Greeting: version, method count, methods.
            guard bytes.count >= 2, bytes.count >= 2 + Int(bytes[1]) else { return nil }
            session.input.removeAll()
            session.state["step"] = "request"
            return Data([0x05, 0x00])
        case "request":
            // Version, command, reserved, address type, address, port.
            guard bytes.count >= 5 else { return nil }
            let portStart: Int
            switch bytes[3] {
            case 0x01: portStart = 8
            case 0x03: portStart = 5 + Int(bytes[4])
            case 0x04: portStart = 20
            default: return Data()
            }
            guard bytes.count >= portStart + 2 else { return nil }
            session.state["port"] = String(Int(bytes[portStart]) << 8 | Int(bytes[portStart + 1]))
            session.input.removeAll()
            session.state["step"] = "done"
            // Reply 5: connection refused.
            return Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        default:
            return nil
        }
    }

    func testCheckGoesThroughTheProxyOnly() async throws {
        let node = try await start(Self.monerod(login: "kc", password: "right"))
        let proxy = try await start(Self.refusingSocksProxy)

        let result = await check(node, NodeCredentials(login: "kc", password: "right"), proxy: "localhost:\(proxy.port)")

        XCTAssertEqual(result, .inconclusive)
        XCTAssertEqual(node.connectionCount, 0, "The check never connects to the node directly")
        let ports = proxy.states.compactMap { $0["port"] }
        XCTAssertFalse(ports.isEmpty, "The check asked the proxy for the node")
        XCTAssertEqual(Set(ports), [String(node.port)])
    }

    /// Clears the node settings a NodeManager reads and writes, and puts them
    /// back after the test. Auto-select stays off, so no test switches nodes.
    private func isolateNodeSettings() {
        let saved = SavedNodeSettings()
        addTeardownBlock { saved.restore() }
        ["customNodes", "selectedNodeURL", "isTestnet", "proxyAddress"].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
        UserDefaults.standard.set(false, forKey: "autoSelectNode")
    }

    /// Turning Tor on in settings writes only the wallet's proxy setting, so
    /// the manager's `proxyAddress` is still empty. The row check must use
    /// the wallet's setting and never connect around the proxy.
    @MainActor
    func testNodeRowCheckGoesThroughTheWalletProxy() async throws {
        isolateNodeSettings()
        let node = try await start(Self.monerod(login: "kc", password: "right"))
        let proxy = try await start(Self.refusingSocksProxy)
        let url = "http://localhost:\(node.port)"
        let fake = FakeNodeKeychain()
        let manager = NodeManager(keychain: fake.keychain)
        manager.addCustomNode(name: "Lab", url: url, login: "kc", password: "wrong")

        // With no proxy set, the check asks the node, which turns the login down.
        let rejectedDirectly = await manager.loginRejected(at: url, timeout: 5)
        XCTAssertTrue(rejectedDirectly)
        XCTAssertEqual(node.connectionCount, 1)

        UserDefaults.standard.set("localhost:\(proxy.port)", forKey: "proxyAddress")
        XCTAssertEqual(manager.proxyAddress, "")

        let rejectedThroughProxy = await manager.loginRejected(at: url, timeout: 5)

        XCTAssertFalse(rejectedThroughProxy, "The proxy cannot reach the node, so the check has no answer")
        XCTAssertEqual(node.connectionCount, 1, "The check never connects around the proxy")
        XCTAssertEqual(Set(proxy.states.compactMap { $0["port"] }), [String(node.port)])
    }

    @MainActor
    func testNodeRowCheckSkipsBuiltInNodes() async throws {
        isolateNodeSettings()
        let manager = NodeManager(keychain: FakeNodeKeychain().keychain)

        for builtIn in NodeManager.defaultNodes {
            let rejected = await manager.loginRejected(at: builtIn.url, timeout: 5)
            XCTAssertFalse(rejected, builtIn.url)
        }
    }

    /// Network.framework connects to some local addresses directly even with
    /// a proxy set, so with a proxy the check skips a node at such an address.
    func testWithAProxyTheCheckSkipsANodeAtALocalAddress() async throws {
        let node = try await start(Self.monerod(login: "kc", password: "right"))
        let proxy = try await start(Self.refusingSocksProxy)
        let url = "http://127.0.0.1:\(node.port)"
        let wrong = NodeCredentials(login: "kc", password: "wrong")

        let direct = await NodeLoginProbe.check(url: url, credentials: wrong, proxy: "", timeout: 5)
        XCTAssertEqual(direct, .rejected, "With no proxy the check asks the node")
        XCTAssertEqual(node.connectionCount, 1)

        let skipped = await NodeLoginProbe.check(url: url, credentials: wrong, proxy: "localhost:\(proxy.port)", timeout: 5)

        XCTAssertEqual(skipped, .inconclusive)
        XCTAssertEqual(node.connectionCount, 1, "The check never connects around the proxy")
        XCTAssertEqual(proxy.connectionCount, 0, "The check is skipped")
    }

    func testWithAProxyTheCheckSkipsIPv6Loopback() async throws {
        try await assertSkippedWithAProxy(host: "[::1]")
    }

    func testWithAProxyTheCheckSkipsAnIPv4MappedLoopback() async throws {
        try await assertSkippedWithAProxy(host: "[::ffff:127.0.0.1]")
    }

    /// With no proxy the check reaches the node at `host`. With a proxy it
    /// has no answer, and it connects to neither the node nor the proxy.
    private func assertSkippedWithAProxy(host: String, line: UInt = #line) async throws {
        let node = try await start(Self.monerod(login: "kc", password: "right"))
        let proxy = try await start(Self.refusingSocksProxy)
        let url = "http://\(host):\(node.port)"
        let wrong = NodeCredentials(login: "kc", password: "wrong")

        let direct = await NodeLoginProbe.check(url: url, credentials: wrong, proxy: "", timeout: 5)
        XCTAssertEqual(direct, .rejected, "With no proxy the check asks the node", line: line)

        let skipped = await NodeLoginProbe.check(url: url, credentials: wrong, proxy: "localhost:\(proxy.port)", timeout: 5)

        XCTAssertEqual(skipped, .inconclusive, line: line)
        XCTAssertEqual(node.connectionCount, 1, "The check never connects around the proxy", line: line)
        XCTAssertEqual(proxy.connectionCount, 0, "The check is skipped", line: line)
    }

    func testWithAProxyTheCheckAsksTheProxyForAPublicAddress() async throws {
        let proxy = try await start(Self.refusingSocksProxy)

        // A documentation address (RFC 5737): the proxy turns it down.
        let result = await NodeLoginProbe.check(url: "http://192.0.2.1:18089", credentials: .none,
                                                proxy: "localhost:\(proxy.port)", timeout: 5)

        XCTAssertEqual(result, .inconclusive)
        XCTAssertEqual(proxy.states.compactMap { $0["port"] }, ["18089"], "The check asked the proxy for the node")
    }

    func testAddressesOutsidePublicUnicast() {
        let outside = [
            // 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.168/16, 224/4.
            "0.0.0.0", "0.255.255.255", "10.0.0.1", "10.255.255.255", "100.64.0.0", "100.127.255.255",
            "127.0.0.1", "127.255.255.254", "169.254.0.1", "169.254.255.255", "172.16.0.1", "172.31.255.255",
            "192.168.0.1", "192.168.255.255", "224.0.0.1", "239.255.255.255",
            // Spellings the connection reads as 127.0.0.1.
            "127.1", "2130706433", "0x7f000001", "0127.0.0.1", "::ffff:127.0.0.1", "::ffff:7f00:1",
            // ::, ::1, fe80::/10, fc00::/7, ff00::/8.
            "::", "::1", "fe80::1", "fe80::1%lo0", "febf:ffff::1", "fc00::1", "fdff::1", "ff02::1",
        ]
        let publicOrName = [
            // The addresses next to each range, and documentation addresses.
            "1.0.0.0", "9.255.255.255", "11.0.0.0", "100.63.255.255", "100.128.0.0", "126.255.255.255",
            "128.0.0.0", "169.253.255.255", "169.255.0.0", "172.15.255.255", "172.32.0.0", "192.167.255.255",
            "192.169.0.0", "223.255.255.255", "192.0.2.1", "198.51.100.1", "203.0.113.1",
            "2001:db8::1", "fe7f::1", "fbff::1", "::ffff:192.0.2.1",
            // Names go through the proxy.
            "localhost", "node.monero.one", "127.0.0.1.", "exampleonionnodeforthetest.onion", "999.1.1.1",
        ]

        for host in outside {
            XCTAssertTrue(NodeLoginProbe.isNonPublicAddress(host), host)
        }
        for host in publicOrName {
            XCTAssertFalse(NodeLoginProbe.isNonPublicAddress(host), host)
        }
    }

    func testProxyThatIsNotHostAndPortIsInconclusive() async {
        let result = await NodeLoginProbe.check(url: "http://localhost:18081", credentials: .none, proxy: "localhost", timeout: 5)

        XCTAssertEqual(result, .inconclusive)
    }

    func testOnionNodeWithoutProxyIsInconclusive() async {
        let result = await NodeLoginProbe.check(url: "http://exampleonionnodeforthetest.onion:18089", credentials: .none,
                                                proxy: "", timeout: 5)

        XCTAssertEqual(result, .inconclusive)
    }
}
