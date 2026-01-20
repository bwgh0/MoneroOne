import Foundation

struct MoneroNode: Identifiable, Codable, Equatable {
    var id: String { url }
    let name: String
    let url: String
    let isTrusted: Bool

    init(name: String, url: String, isTrusted: Bool = false) {
        self.name = name
        self.url = url
        self.isTrusted = isTrusted
    }
}

@MainActor
class NodeManager: ObservableObject {
    @Published var selectedNode: MoneroNode
    @Published var customNodes: [MoneroNode] = []
    @Published var connectionStatus: ConnectionStatus = .unknown

    enum ConnectionStatus: Equatable {
        case unknown
        case testing
        case connected
        case failed(String)
    }

    static let defaultNodes: [MoneroNode] = [
        MoneroNode(name: "CakeWallet", url: "https://xmr-node.cakewallet.com:18081"),
        MoneroNode(name: "Monerujo", url: "https://node.monerujo.io:18081"),
        MoneroNode(name: "Seth for Privacy", url: "https://node.sethforprivacy.com:18089"),
    ]

    static let defaultTestnetNodes: [MoneroNode] = [
        MoneroNode(name: "Monero Project", url: "http://testnet.xmr-tw.org:28081"),
        MoneroNode(name: "MoneroDevs", url: "http://node.monerodevs.org:28089"),
    ]

    private var selectedNodeKey: String {
        isTestnet ? "selectedTestnetNodeURL" : "selectedNodeURL"
    }
    private var customNodesKey: String {
        isTestnet ? "customTestnetNodes" : "customNodes"
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
        let nodes = testnet ? Self.defaultTestnetNodes : Self.defaultNodes

        // Load selected node from UserDefaults
        let savedURL = UserDefaults.standard.string(forKey: nodeKey) ?? nodes[0].url
        if let node = nodes.first(where: { $0.url == savedURL }) {
            selectedNode = node
        } else {
            // Check custom nodes
            selectedNode = MoneroNode(name: "Custom", url: savedURL)
        }

        // Load custom nodes
        loadCustomNodes()
    }

    func selectNode(_ node: MoneroNode) {
        selectedNode = node
        UserDefaults.standard.set(node.url, forKey: selectedNodeKey)
        connectionStatus = .unknown
    }

    func addCustomNode(name: String, url: String, isTrusted: Bool = false) {
        let node = MoneroNode(name: name, url: url, isTrusted: isTrusted)
        customNodes.append(node)
        saveCustomNodes()
    }

    func removeCustomNode(_ node: MoneroNode) {
        customNodes.removeAll { $0.id == node.id }
        saveCustomNodes()

        // If removed node was selected, switch to default
        if selectedNode.id == node.id {
            selectNode(currentDefaultNodes[0])
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

    func testConnection() async {
        connectionStatus = .testing

        guard let baseURL = URL(string: selectedNode.url) else {
            connectionStatus = .failed("Invalid URL")
            return
        }

        // Use JSON-RPC format that Monero nodes expect
        let rpcURL = baseURL.appendingPathComponent("json_rpc")
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"jsonrpc":"2.0","id":"0","method":"get_info"}"#.data(using: .utf8)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["result"] != nil {
                connectionStatus = .connected
            } else {
                connectionStatus = .failed("Node not responding")
            }
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }
}
