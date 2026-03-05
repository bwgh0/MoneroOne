import Foundation
import Network

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
                selectBestNode()
            }
        }
    }
    @Published var nodeStats: [String: NodeStats] = [:]
    @Published var isLoadingStats: Bool = false

    private var uptimeStatsCache: [UptimeSummaryEntry]?
    private var uptimeCacheTime: Date?
    private let uptimeCacheDuration: TimeInterval = 3600 // 1 hour

    static let defaultNodes: [MoneroNode] = [
        MoneroNode(name: "Hashvault", url: "https://nodes.hashvault.pro:18081"),
        MoneroNode(name: "Seth for Privacy", url: "https://node.sethforprivacy.com:18089"),
        MoneroNode(name: "CakeWallet", url: "https://xmr-node.cakewallet.com:18081"),
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

    private func applyUptimeCache() {
        guard let entries = uptimeStatsCache else { return }

        for node in allNodes {
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
                #if DEBUG
                // DEBUG ONLY: Accept all certificates for latency testing
                // In release builds, use default certificate validation
                let tlsOptions = NWProtocolTLS.Options()
                sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
                    complete(true)
                }, DispatchQueue.global())
                parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
                #else
                // Production: Use default TLS with proper certificate validation
                parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
                #endif
            } else {
                parameters = NWParameters.tcp
            }

            let connection = NWConnection(to: endpoint, using: parameters)
            let startTime = CFAbsoluteTimeGetCurrent()
            var hasResumed = false

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

            connection.start(queue: DispatchQueue.global())

            // Timeout after 10 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
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
        await fetchUptimeStats()
        await measureAllLatencies()
        // isLoadingStats is set to false in measureAllLatencies
    }
}
