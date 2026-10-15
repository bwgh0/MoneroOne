import Foundation
import Network
import Security

struct ProxyEntry: Identifiable, Codable, Equatable {
    var id: String { address }
    let name: String
    let address: String // "host:port"
}

struct MoneroNode: Identifiable, Codable, Equatable {
    var id: String { url }
    let name: String
    let url: String
    let isTrusted: Bool
    /// Held in memory only. A custom node's login lives in the Keychain
    /// (`NodeCredentialStore`), and `encode(to:)` leaves it out.
    let login: String?
    let password: String?

    init(name: String, url: String, isTrusted: Bool = false, login: String? = nil, password: String? = nil) {
        self.name = name
        self.url = url
        self.isTrusted = isTrusted
        self.login = login
        self.password = password
    }

    var hasCredentials: Bool {
        login != nil && !(login?.isEmpty ?? true)
    }

    var credentials: NodeCredentials {
        NodeCredentials(login: login, password: password)
    }

    /// The same node with another login.
    func with(_ credentials: NodeCredentials) -> MoneroNode {
        MoneroNode(name: name, url: url, isTrusted: isTrusted, login: credentials.login, password: credentials.password)
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, isTrusted, login, password
    }

    // Decoding still reads `login` and `password`. Lists that earlier builds
    // saved hold them in plain text, and the launch migration moves them
    // into the Keychain.

    /// Writes the name, the URL and the trust flag only, so no encoded node
    /// carries a login.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(isTrusted, forKey: .isTrusted)
    }
}

extension MoneroNode: CustomStringConvertible, CustomDebugStringConvertible {
    // Leaves the login out, so a log line that prints a node cannot leak it.
    var description: String {
        "MoneroNode(name: \(name), url: \(url), hasCredentials: \(hasCredentials))"
    }

    var debugDescription: String { description }
}

/// A custom node as the UserDefaults list stores it: the same fields that
/// earlier builds wrote. It carries a login only while that login's
/// Keychain write has not gone through.
private struct StoredCustomNode: Encodable {
    let name: String
    let url: String
    let isTrusted: Bool
    let login: String?
    let password: String?

    init(_ node: MoneroNode, keepsLogin: Bool) {
        name = node.name
        url = node.url
        isTrusted = node.isTrusted
        login = keepsLogin ? node.credentials.login : nil
        password = keepsLogin ? node.credentials.password : nil
    }
}

/// A node's RPC login and password. Empty fields count as none, as in
/// `NodeCredentialStore`.
struct NodeCredentials: Equatable {
    let login: String?
    let password: String?

    init(login: String?, password: String?) {
        self.login = login?.isEmpty == false ? login : nil
        self.password = password?.isEmpty == false ? password : nil
    }

    static let none = NodeCredentials(login: nil, password: nil)

    var isEmpty: Bool { login == nil && password == nil }
}

extension NodeCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    // Never prints the values, so a log line or a test failure cannot leak them.
    var description: String { isEmpty ? "NodeCredentials(none)" : "NodeCredentials(***)" }
    var debugDescription: String { description }
}

struct NodeStats {
    let uptimeMonth: Double?   // e.g. 99.5, nil if unknown
    let uptimeYear: Double?    // e.g. 99.8, nil if unknown
    let isUp: Bool
    var latencyMs: Int?        // measured locally, nil if not tested

    var score: Double {
        guard let latency = latencyMs, latency > 0 else { return 0 }
        // For unknown uptime, use 95% as neutral assumption for ranking
        let uptime = uptimeMonth ?? 95.0
        return uptime / Double(latency)  // higher = better
    }

    var uptimeColor: UptimeColor {
        guard let uptime = uptimeMonth else {
            // No uptime data — if latency is good, the node is up
            return latencyMs != nil ? .green : .unknown
        }
        if uptime >= 99.0 {
            return .green
        } else if uptime >= 95.0 {
            return .yellow
        } else {
            return .red
        }
    }

    enum UptimeColor {
        case green, yellow, red, unknown
    }
}

// MARK: - Secure Node Credential Storage

/// Stores node RPC credentials in the Keychain instead of UserDefaults.
///
/// It keeps two kinds of item in one service:
/// - The selected node's login (`nodeLogin` and `nodePassword`, one pair per
///   network). The wallet reads it when it starts.
/// - One item per custom node, which holds that node's login and password.
///   The node list in UserDefaults keeps only the name, the URL and the
///   trust flag.
struct NodeCredentialStore {
    private static let service = "one.monero.MoneroOne.nodeCredentials"

    /// Item access by account within the store's service. `live` is the
    /// Keychain. Tests pass a fake that can fail a write.
    struct Keychain {
        var read: (_ account: String) -> Data?
        /// True when the write went through.
        var write: (_ account: String, _ data: Data) -> Bool
        var delete: (_ account: String) -> Void

        /// Generic-password items that open after the first unlock and stay
        /// on this device. A write updates the item in place, so a write
        /// that fails leaves the earlier value.
        static let live = Keychain(
            read: { account in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess else { return nil }
                return result as? Data
            },
            write: { account, data in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ]
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                if status == errSecItemNotFound {
                    let addQuery = query.merging(attributes) { _, new in new }
                    status = SecItemAdd(addQuery as CFDictionary, nil)
                }
                return status == errSecSuccess
            },
            delete: { account in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ]
                SecItemDelete(query as CFDictionary)
            }
        )
    }

    static func save(login: String?, password: String?, isTestnet: Bool, keychain: Keychain = .live) {
        let loginKey = isTestnet ? "testnetNodeLogin" : "nodeLogin"
        let passwordKey = isTestnet ? "testnetNodePassword" : "nodePassword"
        set(loginKey, value: login, keychain: keychain)
        set(passwordKey, value: password, keychain: keychain)
    }

    static func load(isTestnet: Bool, keychain: Keychain = .live) -> (login: String?, password: String?) {
        let loginKey = isTestnet ? "testnetNodeLogin" : "nodeLogin"
        let passwordKey = isTestnet ? "testnetNodePassword" : "nodePassword"
        return (get(loginKey, keychain: keychain), get(passwordKey, keychain: keychain))
    }

    static func clear(isTestnet: Bool, keychain: Keychain = .live) {
        save(login: nil, password: nil, isTestnet: isTestnet, keychain: keychain)
    }

    // MARK: Custom Node Logins

    /// The item of one custom node: the network, then the URL exactly as the
    /// node list stores it. The app matches nodes by that exact string
    /// everywhere else (node ids, the selected URL), so a looser form could
    /// give two listed nodes one item.
    static func nodeAccount(url: String, isTestnet: Bool) -> String {
        (isTestnet ? "node.testnet." : "node.mainnet.") + url
    }

    /// The login stored for a custom node, or nil when it has none.
    static func loadNode(url: String, isTestnet: Bool, keychain: Keychain = .live) -> NodeCredentials? {
        guard let data = keychain.read(nodeAccount(url: url, isTestnet: isTestnet)),
              let item = try? JSONDecoder().decode(NodeLoginItem.self, from: data) else { return nil }
        let credentials = NodeCredentials(login: item.login, password: item.password)
        return credentials.isEmpty ? nil : credentials
    }

    /// Stores a custom node's login and password as one item, then reads the
    /// item back. True only when that read returns the same login. A node
    /// with no login gets its item removed.
    @discardableResult
    static func saveNode(url: String, credentials: NodeCredentials, isTestnet: Bool, keychain: Keychain = .live) -> Bool {
        guard !credentials.isEmpty else {
            removeNode(url: url, isTestnet: isTestnet, keychain: keychain)
            return loadNode(url: url, isTestnet: isTestnet, keychain: keychain) == nil
        }
        let item = NodeLoginItem(login: credentials.login, password: credentials.password)
        guard let data = try? JSONEncoder().encode(item) else { return false }
        _ = keychain.write(nodeAccount(url: url, isTestnet: isTestnet), data)
        return loadNode(url: url, isTestnet: isTestnet, keychain: keychain) == credentials
    }

    static func removeNode(url: String, isTestnet: Bool, keychain: Keychain = .live) {
        keychain.delete(nodeAccount(url: url, isTestnet: isTestnet))
    }

    /// The data of a custom node's item.
    private struct NodeLoginItem: Codable {
        let login: String?
        let password: String?
    }

    /// One-time migration from UserDefaults to Keychain
    static func migrateFromUserDefaultsIfNeeded() {
        let migrated = UserDefaults.standard.bool(forKey: "nodeCredsMigratedToKeychain")
        guard !migrated else { return }

        for testnet in [false, true] {
            let loginKey = testnet ? "selectedTestnetNodeLogin" : "selectedNodeLogin"
            let passwordKey = testnet ? "selectedTestnetNodePassword" : "selectedNodePassword"
            let login = UserDefaults.standard.string(forKey: loginKey)
            let password = UserDefaults.standard.string(forKey: passwordKey)
            if login != nil || password != nil {
                save(login: login, password: password, isTestnet: testnet)
                UserDefaults.standard.removeObject(forKey: loginKey)
                UserDefaults.standard.removeObject(forKey: passwordKey)
            }
        }
        UserDefaults.standard.set(true, forKey: "nodeCredsMigratedToKeychain")
    }

    private static func set(_ key: String, value: String?, keychain: Keychain) {
        // Delete existing
        keychain.delete(key)

        guard let value = value, !value.isEmpty,
              let data = value.data(using: .utf8) else { return }

        _ = keychain.write(key, data)
    }

    private static func get(_ key: String, keychain: Keychain) -> String? {
        guard let data = keychain.read(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// Response from Cake Upptime API
struct UptimeSummaryEntry: Codable {
    let name: String
    let url: String
    let status: String
    let uptimeDay: String?
    let uptimeWeek: String?
    let uptimeMonth: String?
    let uptimeYear: String?
}

@MainActor
class NodeManager: ObservableObject {
    @Published var selectedNode: MoneroNode
    @Published var customNodes: [MoneroNode] = []
    @Published var autoSelectEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSelectEnabled, forKey: autoSelectKey)
            if autoSelectEnabled {
                Task { selectBestNode() }
            }
        }
    }
    @Published var nodeStats: [String: NodeStats] = [
        // Monero One: always 100% uptime
        "https://node.monero.one:443": NodeStats(uptimeMonth: 100.0, uptimeYear: 100.0, isUp: true, latencyMs: nil)
    ]
    @Published var isLoadingStats: Bool = false
    @Published var proxyAddress: String = ""
    @Published var customProxies: [ProxyEntry] = []
    @Published var selectedProxyAddress: String = ""
    @Published var proxyReachability: [String: Bool] = [:]

    var selectedProxyReachable: Bool? {
        proxyReachability[selectedProxyAddress]
    }

    private var uptimeStatsCache: [UptimeSummaryEntry]?
    private var uptimeCacheTime: Date?
    private let uptimeCacheDuration: TimeInterval = 3600 // 1 hour

    /// Where node logins live. Tests pass a fake.
    private let keychain: NodeCredentialStore.Keychain

    static let defaultNodes: [MoneroNode] = [
        MoneroNode(name: "Monero One", url: "https://node.monero.one:443"),
        MoneroNode(name: "Hashvault", url: "https://nodes.hashvault.pro:18081"),
        MoneroNode(name: "Seth for Privacy", url: "https://node.sethforprivacy.com:18089"),
    ]

    static let defaultProxies: [ProxyEntry] = [
        ProxyEntry(name: "Orbot / Local Tor", address: "127.0.0.1:9050"),
    ]

    static let torNodes: [MoneroNode] = [
        MoneroNode(name: "Monero One (US)", url: "http://5tvl5acn3sm7id4gzc4mj6n7lrwlyrhssr2r57zkxk6eugxwix4ze4qd.onion:18089"),
        MoneroNode(name: "Monero One (EU)", url: "http://zu3oyzi45x3ul24sncs4245nlpz76jzizm36tvrkfvq2r33azzjv5syd.onion:18089"),
    ]

    #if DEBUG
    static let defaultTestnetNodes: [MoneroNode] = [
        MoneroNode(name: "Monero Project", url: "http://testnet.xmr-tw.org:28081"),
        MoneroNode(name: "MoneroDevs", url: "http://node.monerodevs.org:28089"),
    ]
    #else
    static let defaultTestnetNodes: [MoneroNode] = []
    #endif

    private var selectedNodeKey: String {
        Self.selectedNodeKey(isTestnet: isTestnet)
    }
    private var customNodesKey: String {
        Self.customNodesKey(isTestnet: isTestnet)
    }
    private static func selectedNodeKey(isTestnet: Bool) -> String {
        isTestnet ? "selectedTestnetNodeURL" : "selectedNodeURL"
    }
    private static func customNodesKey(isTestnet: Bool) -> String {
        isTestnet ? "customTestnetNodes" : "customNodes"
    }
    private var autoSelectKey: String {
        isTestnet ? "autoSelectTestnetNode" : "autoSelectNode"
    }
    var isTestnet: Bool {
        UserDefaults.standard.bool(forKey: "isTestnet")
    }

    var currentDefaultNodes: [MoneroNode] {
        isTestnet ? Self.defaultTestnetNodes : Self.defaultNodes
    }

    init(keychain: NodeCredentialStore.Keychain = .live) {
        self.keychain = keychain

        // Migrate node credentials from UserDefaults to Keychain. The app
        // also runs both at launch; here they are quick no-ops.
        NodeCredentialStore.migrateFromUserDefaultsIfNeeded()
        Self.migrateCustomNodeLogins(keychain: keychain)

        // Determine which node list to use based on network
        let testnet = UserDefaults.standard.bool(forKey: "isTestnet")
        let nodeKey = testnet ? "selectedTestnetNodeURL" : "selectedNodeURL"
        let autoKey = testnet ? "autoSelectTestnetNode" : "autoSelectNode"
        let nodes = testnet ? Self.defaultTestnetNodes : Self.defaultNodes

        // Load auto select setting (default to true for new users)
        self.autoSelectEnabled = UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true

        // Load selected node from UserDefaults (use first default node as fallback)
        let defaultURL = nodes.first?.url ?? "https://nodes.hashvault.pro:18081"
        let savedURL = UserDefaults.standard.string(forKey: nodeKey) ?? defaultURL
        if let node = nodes.first(where: { $0.url == savedURL }) {
            selectedNode = node
        } else {
            // Check custom nodes
            selectedNode = MoneroNode(name: String(localized: "Custom", comment: "Name of a node the user added"), url: savedURL)
        }

        // Load custom nodes
        loadCustomNodes()

        // Load proxy address and proxy list
        self.proxyAddress = UserDefaults.standard.string(forKey: "proxyAddress") ?? ""
        self.selectedProxyAddress = UserDefaults.standard.string(forKey: "selectedProxyAddress") ?? Self.defaultProxies.first?.address ?? ""
        loadCustomProxies()
    }

    var allNodes: [MoneroNode] {
        currentDefaultNodes + customNodes
    }

    func selectNode(_ node: MoneroNode) {
        selectedNode = node
        UserDefaults.standard.set(node.url, forKey: selectedNodeKey)
        // Persist credentials securely in Keychain
        NodeCredentialStore.save(login: node.login, password: node.password, isTestnet: isTestnet, keychain: keychain)
    }

    func addCustomNode(name: String, url: String, isTrusted: Bool = false, login: String? = nil, password: String? = nil) {
        var credentials = NodeCredentials(login: login, password: password)
        // A copy added with no login takes the login its URL already has.
        if credentials.isEmpty, let listed = listedLogin(of: url) {
            credentials = listed
        }
        customNodes.append(MoneroNode(name: name, url: url, isTrusted: isTrusted))
        setLogin(credentials, of: url)
        saveCustomNodes()
    }

    func removeCustomNode(_ node: MoneroNode) {
        customNodes.removeAll { $0.id == node.id }
        saveCustomNodes()
        // No listed node has this URL now, so its login goes too.
        NodeCredentialStore.removeNode(url: node.url, isTestnet: isTestnet, keychain: keychain)

        // If removed node was selected, switch to default
        if selectedNode.id == node.id {
            if let defaultNode = currentDefaultNodes.first {
                selectNode(defaultNode)
            }
        }
    }

    /// Returns the saved node, which has the login its URL now has.
    @discardableResult
    func updateCustomNode(oldURL: String, name: String, url: String, login: String? = nil, password: String? = nil) -> MoneroNode? {
        guard let index = customNodes.firstIndex(where: { $0.url == oldURL }) else { return nil }
        var others = customNodes
        others.remove(at: index)
        var credentials = NodeCredentials(login: login, password: password)
        // A node moved with no login onto a listed URL takes that URL's login.
        // On the same URL, an empty login removes the login from every copy.
        if credentials.isEmpty, url != oldURL, let listed = listedLogin(of: url) {
            credentials = listed
        }
        customNodes[index] = MoneroNode(name: name, url: url)
        let stored = setLogin(credentials, of: url)
        saveCustomNodes()
        // The login moves with the URL. The old item goes only after the new
        // one holds the login, and only when no other listed node uses it.
        if url != oldURL, stored, !others.contains(where: { $0.url == oldURL }) {
            NodeCredentialStore.removeNode(url: oldURL, isTestnet: isTestnet, keychain: keychain)
        }
        return customNodes[index]
    }

    /// The login of the listed copies of a URL, or nil when no copy has the
    /// URL. When the copies have none, the item's login: a Keychain read that
    /// failed when the list loaded leaves the copies without it.
    private func listedLogin(of url: String) -> NodeCredentials? {
        guard let listed = customNodes.first(where: { $0.url == url }) else { return nil }
        guard listed.credentials.isEmpty else { return listed.credentials }
        return NodeCredentialStore.loadNode(url: url, isTestnet: isTestnet, keychain: keychain) ?? NodeCredentials.none
    }

    /// A URL is one node: ids, the selection and deletes all go by URL. So
    /// every listed copy of a URL has the same login.
    ///
    /// Writes the login of a URL to its Keychain item, or removes the item
    /// when the login is empty, then gives every listed copy of the URL that
    /// login. False when the item does not hold the login; `saveCustomNodes`
    /// then keeps the login in the list.
    @discardableResult
    private func setLogin(_ credentials: NodeCredentials, of url: String) -> Bool {
        let stored = NodeCredentialStore.saveNode(url: url, credentials: credentials, isTestnet: isTestnet, keychain: keychain)
        customNodes = customNodes.map { $0.url == url ? $0.with(credentials) : $0 }
        // The wallet reads the selected node's login when it starts, and the
        // launch migration lets that login win. So it follows the URL's login.
        if url == selectedNode.url {
            NodeCredentialStore.save(login: credentials.login, password: credentials.password, isTestnet: isTestnet, keychain: keychain)
        }
        return stored
    }

    /// The node for the edit sheet. Its login comes from the Keychain: the
    /// list loads it from there, and this reads the item again when the
    /// listed copy has none.
    func nodeForEditing(_ node: MoneroNode) -> MoneroNode {
        guard node.credentials.isEmpty,
              let stored = NodeCredentialStore.loadNode(url: node.url, isTestnet: isTestnet, keychain: keychain) else {
            return node
        }
        return node.with(stored)
    }

    /// True when an edit changes how the wallet reaches the node. The kit
    /// reads the URL and login only at start, so a change to either needs a
    /// restart. A rename keeps the connection. An empty login and no login
    /// are the same, as in `NodeCredentialStore`.
    static func needsReconnect(from old: MoneroNode, to new: MoneroNode) -> Bool {
        old.url != new.url
            || (old.login ?? "") != (new.login ?? "")
            || (old.password ?? "") != (new.password ?? "")
    }

    /// `needsReconnect(from:to:)` against the Keychain copy of the login.
    /// For the selected node, that is the login the kit read at start. So
    /// when a restored phone has lost that login, saving the node's login
    /// again reconnects.
    func needsReconnect(editing node: MoneroNode, to edited: MoneroNode) -> Bool {
        let stored: NodeCredentials
        if selectedNode.id == node.id {
            let kit = NodeCredentialStore.load(isTestnet: isTestnet, keychain: keychain)
            stored = NodeCredentials(login: kit.login, password: kit.password)
        } else {
            stored = NodeCredentialStore.loadNode(url: node.url, isTestnet: isTestnet, keychain: keychain) ?? .none
        }
        return Self.needsReconnect(from: node.with(stored), to: edited)
    }

    func setProxy(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        proxyAddress = trimmed
        UserDefaults.standard.set(trimmed, forKey: "proxyAddress")
    }

    var allProxies: [ProxyEntry] {
        Self.defaultProxies + customProxies
    }

    func selectProxy(_ proxy: ProxyEntry) {
        selectedProxyAddress = proxy.address
        UserDefaults.standard.set(proxy.address, forKey: "selectedProxyAddress")
        setProxy(proxy.address)
    }

    func addCustomProxy(name: String, address: String) {
        let proxy = ProxyEntry(name: name, address: address)
        customProxies.append(proxy)
        saveCustomProxies()
    }

    func updateCustomProxy(oldAddress: String, name: String, address: String) {
        guard let index = customProxies.firstIndex(where: { $0.address == oldAddress }) else { return }
        customProxies[index] = ProxyEntry(name: name, address: address)
        saveCustomProxies()
    }

    func removeCustomProxy(_ proxy: ProxyEntry) {
        customProxies.removeAll { $0.id == proxy.id }
        saveCustomProxies()

        // If removed proxy was selected, fall back to default
        if selectedProxyAddress == proxy.address {
            if let fallback = Self.defaultProxies.first {
                selectProxy(fallback)
            }
        }
    }

    private func loadCustomProxies() {
        guard let data = UserDefaults.standard.data(forKey: "customProxies"),
              let proxies = try? JSONDecoder().decode([ProxyEntry].self, from: data) else {
            return
        }
        customProxies = proxies
    }

    private func saveCustomProxies() {
        guard let data = try? JSONEncoder().encode(customProxies) else { return }
        UserDefaults.standard.set(data, forKey: "customProxies")
    }

    // MARK: - Proxy Reachability

    func checkAllProxyReachability() async {
        await withTaskGroup(of: (String, Bool).self) { group in
            for proxy in allProxies {
                group.addTask {
                    let reachable = await self.checkReachability(of: proxy.address)
                    return (proxy.address, reachable)
                }
            }
            for await (address, reachable) in group {
                proxyReachability[address] = reachable
            }
        }
    }

    func checkProxyReachability(for address: String) async {
        let reachable = await checkReachability(of: address)
        proxyReachability[address] = reachable
    }

    private func checkReachability(of address: String) async -> Bool {
        let components = address.split(separator: ":")
        guard components.count == 2,
              let port = UInt16(components[1]) else {
            return false
        }
        let host = String(components[0])

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: port)
            )
            let connection = NWConnection(to: endpoint, using: .tcp)
            var hasResumed = false

            // Use a serial queue so stateUpdateHandler and timeout
            // never race on hasResumed.
            let queue = DispatchQueue(label: "one.monero.reachability")

            connection.stateUpdateHandler = { state in
                guard !hasResumed else { return }
                switch state {
                case .ready:
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 2) {
                if !hasResumed {
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func loadCustomNodes() {
        guard let data = UserDefaults.standard.data(forKey: customNodesKey),
              let nodes = try? JSONDecoder().decode([MoneroNode].self, from: data) else {
            return
        }
        // Logins come from the Keychain, one per URL. A login still in the
        // list is waiting for its Keychain write, so it is newer than the
        // item. When copies differ, the last one wins, as in the migration.
        var waiting: [String: NodeCredentials] = [:]
        for node in nodes where !node.credentials.isEmpty {
            waiting[node.url] = node.credentials
        }
        customNodes = nodes.map { node in
            node.with(waiting[node.url]
                ?? NodeCredentialStore.loadNode(url: node.url, isTestnet: isTestnet, keychain: keychain)
                ?? .none)
        }
    }

    private func saveCustomNodes() {
        // The list keeps a login only while its URL's Keychain item does not
        // hold it, so a failed write loses nothing. The launch migration
        // moves it later. No copy keeps a login once the item holds the
        // login of any copy of its URL.
        let inKeychain = Set(customNodes.filter { node in
            !node.credentials.isEmpty
                && NodeCredentialStore.loadNode(url: node.url, isTestnet: isTestnet, keychain: keychain) == node.credentials
        }.map(\.url))
        let stored = customNodes.map { node in
            StoredCustomNode(node, keepsLogin: !node.credentials.isEmpty && !inKeychain.contains(node.url))
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: customNodesKey)
    }

    // MARK: - Login Migration

    /// Moves custom node logins out of the UserDefaults node lists, where
    /// earlier builds kept them in plain text, into one Keychain item per
    /// URL. Runs at launch, for both networks.
    ///
    /// A login leaves the list only after a read of its item returns it.
    /// When a write fails, the login stays in the list and the next launch
    /// tries again, so no path loses a login. Once no list holds a login, a
    /// run only reads the lists and the selected node's login.
    static func migrateCustomNodeLogins(defaults: UserDefaults = .standard, keychain: NodeCredentialStore.Keychain = .live) {
        for isTestnet in [false, true] {
            migrateCustomNodeLogins(isTestnet: isTestnet, defaults: defaults, keychain: keychain)
        }
    }

    private static func migrateCustomNodeLogins(isTestnet: Bool, defaults: UserDefaults, keychain: NodeCredentialStore.Keychain) {
        let listKey = customNodesKey(isTestnet: isTestnet)
        // Plain JSON objects, so the rewrite removes the two login fields and
        // changes nothing else.
        guard let data = defaults.data(forKey: listKey),
              var entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }

        let selectedURL = defaults.string(forKey: selectedNodeKey(isTestnet: isTestnet))
        let kit = NodeCredentialStore.load(isTestnet: isTestnet, keychain: keychain)
        let kitCredentials = NodeCredentials(login: kit.login, password: kit.password)

        if moveLogins(of: &entries, selectedURL: selectedURL, kitCredentials: kitCredentials,
                      isTestnet: isTestnet, keychain: keychain),
           let newData = try? JSONSerialization.data(withJSONObject: entries) {
            defaults.set(newData, forKey: listKey)
        }

        // After a downgrade, an earlier build clears the selected node's
        // login when the user selects or saves that node, because its list
        // has no logins. The node's item stays, so it gives the wallet the
        // login back. Only when the item holds the URL's login: no copy may
        // still wait for its write.
        if kitCredentials.isEmpty, let selectedURL {
            let copies = entries.filter { $0["url"] as? String == selectedURL }
            if !copies.isEmpty, !copies.contains(where: holdsLogin),
               let stored = NodeCredentialStore.loadNode(url: selectedURL, isTestnet: isTestnet, keychain: keychain) {
                NodeCredentialStore.save(login: stored.login, password: stored.password, isTestnet: isTestnet, keychain: keychain)
            }
        }
    }

    /// Moves the logins that `entries` hold into the Keychain, one per URL,
    /// and removes them from every copy of a URL once its item holds the
    /// login. True when it changed `entries`.
    private static func moveLogins(of entries: inout [[String: Any]], selectedURL: String?, kitCredentials: NodeCredentials,
                                   isTestnet: Bool, keychain: NodeCredentialStore.Keychain) -> Bool {
        var urls: [String] = []
        var listed: [String: NodeCredentials] = [:]
        for entry in entries where holdsLogin(entry) {
            guard let url = entry["url"] as? String else { continue }
            if !urls.contains(url) { urls.append(url) }
            let credentials = NodeCredentials(login: entry["login"] as? String, password: entry["password"] as? String)
            // When copies of a URL differ, the last one wins: Add appends, so it is the newest.
            if !credentials.isEmpty { listed[url] = credentials }
        }

        var moved: Set<String> = []
        for url in urls {
            // A URL with only empty fields has no secret, and the fields simply go.
            if let login = listed[url] {
                // The wallet connects with the selected node's Keychain login,
                // so that login wins. Elsewhere the list's login wins over the
                // item: only an earlier build or a failed write puts a login
                // in the list, so it is the newer one.
                let wanted = url == selectedURL && !kitCredentials.isEmpty ? kitCredentials : login
                let inKeychain = NodeCredentialStore.loadNode(url: url, isTestnet: isTestnet, keychain: keychain) == wanted
                    || NodeCredentialStore.saveNode(url: url, credentials: wanted, isTestnet: isTestnet, keychain: keychain)
                guard inKeychain else { continue }
            }
            moved.insert(url)
        }

        var changed = false
        for index in entries.indices where holdsLogin(entries[index]) {
            guard let url = entries[index]["url"] as? String, moved.contains(url) else { continue }
            entries[index].removeValue(forKey: "login")
            entries[index].removeValue(forKey: "password")
            changed = true
        }
        return changed
    }

    /// True when a list entry has a login or a password field, even an empty one.
    private static func holdsLogin(_ entry: [String: Any]) -> Bool {
        entry["login"] != nil || entry["password"] != nil
    }

    // MARK: - Uptime Stats

    private static let uptimeAPIURL = "https://raw.githubusercontent.com/cake-tech/upptime-monerocom/master/history/summary.json"

    func fetchUptimeStats() async {
        // Check cache
        if let cacheTime = uptimeCacheTime,
           Date().timeIntervalSince(cacheTime) < uptimeCacheDuration,
           uptimeStatsCache != nil {
            applyUptimeCache()
            return
        }

        guard let url = URL(string: Self.uptimeAPIURL) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let entries = try JSONDecoder().decode([UptimeSummaryEntry].self, from: data)
            uptimeStatsCache = entries
            uptimeCacheTime = Date()
            applyUptimeCache()
        } catch {
            // Silently fail - uptime stats are optional
        }
    }

    private static let moneroOneURL = "https://node.monero.one:443"

    private func applyUptimeCache() {
        guard let entries = uptimeStatsCache else { return }

        for node in allNodes {
            // Skip Monero One — hardcoded to 100%
            if node.url == Self.moneroOneURL { continue }

            // Extract host:port from our node URL to match API's "name" field format
            // API uses format like "xmr-node.cakewallet.com:18081"
            guard let nodeURL = URL(string: node.url),
                  let host = nodeURL.host else { continue }
            let port = nodeURL.port ?? (nodeURL.scheme == "https" ? 443 : 80)
            let hostPort = "\(host):\(port)"

            // Find matching entry by host:port
            let entry = entries.first { entry in
                // API name is "hostname:port" format
                return entry.name.lowercased() == hostPort.lowercased()
            }

            if let entry = entry {
                // Parse uptime - remove % sign if present
                let uptimeMonthStr = entry.uptimeMonth?.replacingOccurrences(of: "%", with: "") ?? "0"
                let uptimeYearStr = entry.uptimeYear?.replacingOccurrences(of: "%", with: "") ?? "0"
                let uptimeMonth = Double(uptimeMonthStr) ?? 0
                let uptimeYear = Double(uptimeYearStr) ?? 0
                let isUp = entry.status.lowercased() == "up"

                // Preserve existing latency if we already have it
                let existingLatency = nodeStats[node.url]?.latencyMs

                nodeStats[node.url] = NodeStats(
                    uptimeMonth: uptimeMonth,
                    uptimeYear: uptimeYear,
                    isUp: isUp,
                    latencyMs: existingLatency
                )
            }
        }
    }

    // MARK: - Latency Measurement

    func measureAllLatencies() async {
        isLoadingStats = true

        await withTaskGroup(of: (String, Int?).self) { group in
            for node in allNodes {
                // .onion nodes can't be tested via direct TCP — mark as available if proxy is reachable
                if node.url.contains(".onion") {
                    let isUp = selectedProxyReachable == true
                    nodeStats[node.url] = NodeStats(
                        uptimeMonth: nil,
                        uptimeYear: nil,
                        isUp: isUp,
                        latencyMs: nil
                    )
                    continue
                }
                group.addTask {
                    let latency = await self.measureLatency(for: node)
                    return (node.url, latency)
                }
            }

            for await (url, latency) in group {
                if var stats = nodeStats[url] {
                    stats.latencyMs = latency
                    nodeStats[url] = stats
                } else {
                    // Custom node without uptime data - create stats with just latency
                    nodeStats[url] = NodeStats(
                        uptimeMonth: nil,
                        uptimeYear: nil,
                        isUp: latency != nil,
                        latencyMs: latency
                    )
                }
            }
        }

        // Monero One: ensure 100% uptime (preserve measured latency)
        let moneroOneLatency = nodeStats[Self.moneroOneURL]?.latencyMs
        nodeStats[Self.moneroOneURL] = NodeStats(uptimeMonth: 100.0, uptimeYear: 100.0, isUp: true, latencyMs: moneroOneLatency)

        isLoadingStats = false

        // Auto-select best node if enabled
        if autoSelectEnabled {
            selectBestNode()
        }
    }

    private func measureLatency(for node: MoneroNode) async -> Int? {
        #if DEBUG
        NSLog("[Latency] Starting measurement for %@: %@", node.name, node.url)
        #endif

        guard let url = URL(string: node.url),
              let host = url.host else {
            #if DEBUG
            NSLog("[Latency] Failed to parse URL: %@", node.url)
            #endif
            return nil
        }

        let port = url.port ?? 18081
        let usesTLS = url.scheme == "https"

        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)))

            let parameters: NWParameters
            if usesTLS {
                // Accept self-signed certificates — many community Monero nodes use them
                let tlsOptions = NWProtocolTLS.Options()
                sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
                    complete(true)
                }, DispatchQueue.global())
                parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            } else {
                parameters = NWParameters.tcp
            }

            let connection = NWConnection(to: endpoint, using: parameters)
            let startTime = CFAbsoluteTimeGetCurrent()
            var hasResumed = false

            // Use a serial queue so stateUpdateHandler and timeout
            // never race on hasResumed.
            let queue = DispatchQueue(label: "one.monero.latency")

            connection.stateUpdateHandler = { state in
                guard !hasResumed else { return }

                switch state {
                case .ready:
                    hasResumed = true
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let latencyMs = Int(elapsed * 1000)
                    #if DEBUG
                    NSLog("[Latency] Success for %@: %dms", node.name, latencyMs)
                    #endif
                    connection.cancel()
                    continuation.resume(returning: latencyMs)

                case .failed(let error):
                    hasResumed = true
                    #if DEBUG
                    NSLog("[Latency] Failed for %@: %@", node.name, error.localizedDescription)
                    #endif
                    connection.cancel()
                    continuation.resume(returning: nil)

                case .cancelled:
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: nil)
                    }

                default:
                    break
                }
            }

            connection.start(queue: queue)

            // Timeout after 10 seconds
            queue.asyncAfter(deadline: .now() + 10) {
                if !hasResumed {
                    hasResumed = true
                    #if DEBUG
                    NSLog("[Latency] Timeout for %@", node.name)
                    #endif
                    connection.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Auto Select

    func selectBestNode() {
        guard autoSelectEnabled else { return }

        // Filter to nodes that are up and have latency measured
        let candidates = allNodes.filter { node in
            guard let stats = nodeStats[node.url] else { return false }
            return stats.isUp && stats.latencyMs != nil
        }

        // Sort by score (uptime / latency) descending
        let best = candidates.max { a, b in
            guard let statsA = nodeStats[a.url], let statsB = nodeStats[b.url] else { return true }
            return statsA.score < statsB.score
        }

        if let best = best, selectedNode.url != best.url {
            selectNode(best)
        }
    }

    // MARK: - Combined Refresh

    func refreshStats() async {
        isLoadingStats = true
        if !proxyAddress.isEmpty {
            await checkAllProxyReachability()
        }
        await fetchUptimeStats()
        await measureAllLatencies()
        // isLoadingStats is set to false in measureAllLatencies
    }
}
