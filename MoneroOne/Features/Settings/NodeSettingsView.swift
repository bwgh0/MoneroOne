import SwiftUI

struct RemoteNode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: String
    let isDefault: Bool
}

struct NodeSettingsView: View {
    @AppStorage("selectedNodeURL") private var selectedNodeURL = "https://node.moneroworld.com:18089"
    @State private var customNodeURL = ""
    @State private var showAddNode = false

    private let defaultNodes: [RemoteNode] = [
        RemoteNode(name: "MoneroWorld", url: "https://node.moneroworld.com:18089", isDefault: true),
        RemoteNode(name: "XMR.to", url: "https://node.xmr.to:18081", isDefault: true),
        RemoteNode(name: "MyMonero", url: "https://opennode.xmr-tw.org:18089", isDefault: true),
    ]

    var body: some View {
        List {
            Section("Default Nodes") {
                ForEach(defaultNodes) { node in
                    nodeRow(node: node)
                }
            }

            Section("Custom Node") {
                if !customNodeURL.isEmpty {
                    nodeRow(node: RemoteNode(name: "Custom", url: customNodeURL, isDefault: false))
                }

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
                    testConnection()
                } label: {
                    HStack {
                        Image(systemName: "network")
                        Text("Test Connection")
                    }
                }
            }
        }
        .navigationTitle("Remote Node")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Add Custom Node", isPresented: $showAddNode) {
            TextField("Node URL", text: $customNodeURL)
            Button("Cancel", role: .cancel) { }
            Button("Add") {
                selectedNodeURL = customNodeURL
            }
        } message: {
            Text("Enter the full URL including port (e.g., https://node.example.com:18089)")
        }
    }

    private func nodeRow(node: RemoteNode) -> some View {
        Button {
            selectedNodeURL = node.url
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

                if selectedNodeURL == node.url {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private func testConnection() {
        // In real implementation, test connection to selected node
    }
}

#Preview {
    NavigationStack {
        NodeSettingsView()
    }
}
