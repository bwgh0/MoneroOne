import SwiftUI

struct NodeSettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @StateObject private var nodeManager = NodeManager()
    @State private var customNodeName = ""
    @State private var customNodeURL = ""
    @State private var showAddNode = false
    @State private var showRestartAlert = false

    var body: some View {
        List {
            Section(nodeManager.isTestnet ? "Testnet Nodes" : "Default Nodes") {
                ForEach(nodeManager.currentDefaultNodes) { node in
                    nodeRow(node: node)
                }
            }

            if !nodeManager.customNodes.isEmpty {
                Section("Custom Nodes") {
                    ForEach(nodeManager.customNodes) { node in
                        nodeRow(node: node)
                    }
                    .onDelete(perform: deleteCustomNode)
                }
            }

            Section {
                Button {
                    showAddNode = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.orange)
                        Text("Add Custom Node")
                    }
                }
            }

            Section {
                Button {
                    Task {
                        await nodeManager.testConnection()
                    }
                } label: {
                    HStack {
                        Image(systemName: "network")
                        Text("Test Connection")
                        Spacer()
                        connectionStatusView
                    }
                }
            }
        }
        .navigationTitle(nodeManager.isTestnet ? "Remote Node (Testnet)" : "Remote Node")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Add Custom Node", isPresented: $showAddNode) {
            TextField("Name (e.g., My Node)", text: $customNodeName)
            TextField("URL (e.g., https://node.example.com:18089)", text: $customNodeURL)
            Button("Cancel", role: .cancel) {
                customNodeName = ""
                customNodeURL = ""
            }
            Button("Add") {
                addCustomNode()
            }
        } message: {
            Text("Enter the node details")
        }
        .alert("Node Changed", isPresented: $showRestartAlert) {
            Button("OK") { }
        } message: {
            Text("The new node will be used when you next open the app.")
        }
    }

    private func nodeRow(node: MoneroNode) -> some View {
        Button {
            selectNode(node)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name)
                        .foregroundColor(.primary)
                    Text(node.url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if nodeManager.selectedNode.id == node.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch nodeManager.connectionStatus {
        case .unknown:
            EmptyView()
        case .testing:
            ProgressView()
                .scaleEffect(0.8)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private func selectNode(_ node: MoneroNode) {
        let previousNode = nodeManager.selectedNode
        nodeManager.selectNode(node)
        walletManager.setNode(url: node.url, isTrusted: node.isTrusted)

        // Show restart alert if node changed and wallet is unlocked
        if previousNode.id != node.id && walletManager.isUnlocked {
            showRestartAlert = true
        }
    }

    private func addCustomNode() {
        guard !customNodeName.isEmpty, !customNodeURL.isEmpty else { return }
        nodeManager.addCustomNode(name: customNodeName, url: customNodeURL)
        customNodeName = ""
        customNodeURL = ""
    }

    private func deleteCustomNode(at offsets: IndexSet) {
        for index in offsets {
            let node = nodeManager.customNodes[index]
            nodeManager.removeCustomNode(node)
        }
    }
}

#Preview {
    NavigationStack {
        NodeSettingsView()
            .environmentObject(WalletManager())
    }
}
