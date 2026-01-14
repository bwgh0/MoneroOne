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

    private let selectedNodeKey = "selectedNodeURL"
    private let customNodesKey = "customNodes"

    init() {
        // Load selected node from UserDefaults
        let savedURL = UserDefaults.standard.string(forKey: selectedNodeKey) ?? Self.defaultNodes[0].url
        if let node = Self.defaultNodes.first(where: { $0.url == savedURL }) {
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
            selectNode(Self.defaultNodes[0])
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

        guard let url = URL(string: selectedNode.url) else {
            connectionStatus = .failed("Invalid URL")
            return
        }

        // Simple HTTP check to see if node responds
        var request = URLRequest(url: url.appendingPathComponent("get_info"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                connectionStatus = .connected
            } else {
                connectionStatus = .failed("Node not responding")
            }
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }
}
