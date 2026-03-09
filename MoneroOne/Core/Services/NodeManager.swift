import Foundation
import Network

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
        isTestnet ? "selectedTestnetNodeURL" : "selectedNodeURL"
    }
    private var customNodesKey: String {
        isTestnet ? "customTestnetNodes" : "customNodes"
    }
    private var autoSelectKey: String {
        isTestnet ? "autoSelectTestnetNode" : "autoSelectNode"
    }
    private var selectedNodeLoginKey: String {
        isTestnet ? "selectedTestnetNodeLogin" : "selectedNodeLogin"
    }
    private var selectedNodePasswordKey: String {
        isTestnet ? "selectedTestnetNodePassword" : "selectedNodePassword"
    }

    var isTestnet: Bool {
        UserDefaults.standard.bool(forKey: "isTestnet")
    }

    var currentDefaultNodes: [MoneroNode] {
        isTestnet ? Self.defaultTestnetNodes : Self.defaultNodes
    }

    init() {
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
            selectedNode = MoneroNode(name: "Custom", url: savedURL)
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
        // Persist credentials (or clear them for nodes without auth)
        UserDefaults.standard.set(node.login, forKey: selectedNodeLoginKey)
        UserDefaults.standard.set(node.password, forKey: selectedNodePasswordKey)
    }

    func addCustomNode(name: String, url: String, isTrusted: Bool = false, login: String? = nil, password: String? = nil) {
        let node = MoneroNode(name: name, url: url, isTrusted: isTrusted, login: login, password: password)
        customNodes.append(node)
        saveCustomNodes()
    }

    func removeCustomNode(_ node: MoneroNode) {
        customNodes.removeAll { $0.id == node.id }
        saveCustomNodes()

        // If removed node was selected, switch to default
        if selectedNode.id == node.id {
            if let defaultNode = currentDefaultNodes.first {
                selectNode(defaultNode)
            }
        }
    }

    func updateCustomNode(oldURL: String, name: String, url: String, login: String? = nil, password: String? = nil) {
        guard let index = customNodes.firstIndex(where: { $0.url == oldURL }) else { return }
        customNodes[index] = MoneroNode(name: name, url: url, login: login, password: password)
        saveCustomNodes()
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
        customNodes = nodes
    }

    private func saveCustomNodes() {
        guard let data = try? JSONEncoder().encode(customNodes) else { return }
        UserDefaults.standard.set(data, forKey: customNodesKey)
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
