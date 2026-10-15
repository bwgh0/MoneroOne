import XCTest
@testable import MoneroOne

@MainActor
final class NodeManagerTests: XCTestCase {

    var nodeManager: NodeManager!

    override func setUp() async throws {
        // Clear any saved state
        UserDefaults.standard.removeObject(forKey: "selectedNodeURL")
        UserDefaults.standard.removeObject(forKey: "customNodes")
        nodeManager = NodeManager()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "selectedNodeURL")
        UserDefaults.standard.removeObject(forKey: "customNodes")
        nodeManager = nil
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
        let newManager = NodeManager()
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

        let newManager = NodeManager()
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

    override func setUp() async throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        fake = FakeNodeKeychain()
        manager = NodeManager(keychain: fake.keychain)
    }

    override func tearDown() async throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        manager = nil
        fake = nil
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
        XCTAssertEqual(NodeManager(keychain: fake.keychain).customNodes.map(\.credentials), [login, login])
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
        XCTAssertEqual(NodeManager(keychain: fake.keychain).customNodes.map(\.credentials), [login, login])
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

        let none = [NodeCredentials.none, NodeCredentials.none]
        XCTAssertNil(item(home))
        XCTAssertEqual(manager.customNodes.map(\.credentials), none)
        XCTAssertEqual(NodeManager(keychain: fake.keychain).customNodes.map(\.credentials), none)
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
        XCTAssertEqual(NodeManager(keychain: fake.keychain).customNodes.map(\.credentials), [login, login])

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
