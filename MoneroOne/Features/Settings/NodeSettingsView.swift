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
            // Auto Select Section
            Section {
                Toggle(isOn: $nodeManager.autoSelectEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto Select")
                            .font(.body)
                        Text("Automatically picks fastest reliable node")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.orange)
            }

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

        }
        .navigationTitle(nodeManager.isTestnet ? "Remote Node (Testnet)" : "Remote Node")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await nodeManager.refreshStats()
        }
        .task {
            await nodeManager.refreshStats()
        }
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
        let isSelected = nodeManager.selectedNode.id == node.id
        let stats = nodeManager.nodeStats[node.url]

        return Button {
            if !nodeManager.autoSelectEnabled {
                selectNode(node)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(node.name)
                            .foregroundColor(nodeManager.autoSelectEnabled && !isSelected ? .secondary : .primary)

                        if isSelected && nodeManager.autoSelectEnabled {
                            Text("Auto")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .clipShape(Capsule())
                        }
                    }

                    Text(node.url)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Stats row
                    if let stats = stats {
                        HStack(spacing: 8) {
                            // Uptime indicator
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(uptimeColor(for: stats))
                                    .frame(width: 8, height: 8)
                                if let uptime = stats.uptimeMonth {
                                    Text(String(format: "%.1f%% uptime", uptime))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Unknown uptime")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Latency
                            if let latency = stats.latencyMs {
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text("\(latency)ms")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else if nodeManager.isLoadingStats {
                                ProgressView()
                                    .scaleEffect(0.5)
                            } else {
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text("--")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else if nodeManager.isLoadingStats {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.5)
                            Text("Checking...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.orange)
                }
            }
        }
        .disabled(nodeManager.autoSelectEnabled)
        .opacity(nodeManager.autoSelectEnabled && !isSelected ? 0.5 : 1.0)
    }

    private func uptimeColor(for stats: NodeStats) -> Color {
        switch stats.uptimeColor {
        case .green:
            return .green
        case .yellow:
            return .yellow
        case .red:
            return .red
        case .unknown:
            return .gray
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
        // Measure latency for the newly added node
        Task {
            await nodeManager.refreshStats()
        }
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
