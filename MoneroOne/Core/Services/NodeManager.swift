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

        // Load selected node from UserDefaults (use first default node as fallback)
        let defaultURL = nodes.first?.url ?? "https://xmr-node.cakewallet.com:18081"
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

    // Custom session that allows older TLS versions (matches wallet2 behavior)
    private lazy var testSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: TLSDelegate(), delegateQueue: nil)
    }()

    func testConnection() async {
        connectionStatus = .testing

        guard let baseURL = URL(string: selectedNode.url) else {
            connectionStatus = .failed("Invalid URL")
            return
        }

        // Try the /get_info endpoint first (works with most public nodes)
        let infoURL = baseURL.appendingPathComponent("get_info")
        var request = URLRequest(url: infoURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await testSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    // Check if response contains expected fields
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       json["height"] != nil || json["status"] != nil {
                        connectionStatus = .connected
                        return
                    }
                }
                // Try JSON-RPC as fallback
                await testConnectionViaJsonRpc(baseURL: baseURL)
            } else {
                connectionStatus = .failed("Invalid response")
            }
        } catch let error as URLError {
            // Provide more specific error messages
            switch error.code {
            case .notConnectedToInternet:
                connectionStatus = .failed("No internet")
            case .timedOut:
                connectionStatus = .failed("Timed out")
            case .cannotConnectToHost:
                connectionStatus = .failed("Can't connect")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                // Try JSON-RPC as fallback for SSL issues
                await testConnectionViaJsonRpc(baseURL: baseURL)
            default:
                connectionStatus = .failed("Network error")
            }
        } catch {
            // Try JSON-RPC as fallback
            await testConnectionViaJsonRpc(baseURL: baseURL)
        }
    }

    private func testConnectionViaJsonRpc(baseURL: URL) async {
        let rpcURL = baseURL.appendingPathComponent("json_rpc")
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"jsonrpc":"2.0","id":"0","method":"get_info"}"#.data(using: .utf8)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await testSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["result"] != nil {
                connectionStatus = .connected
            } else {
                connectionStatus = .failed("Not responding")
            }
        } catch {
            connectionStatus = .failed("RPC failed")
        }
    }
}

// Delegate to handle TLS certificate validation (matches wallet2 behavior)
private class TLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Accept server certificates for Monero nodes (wallet2 does the same)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
