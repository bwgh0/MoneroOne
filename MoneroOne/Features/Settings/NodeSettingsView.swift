import SwiftUI

struct NodeSettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @StateObject private var nodeManager = NodeManager()
    @State private var showAddNode = false
    @State private var editingNode: MoneroNode? = nil
    @State private var proxyText: String = ""

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
                        HStack {
                            nodeRow(node: node)
                            Button {
                                editingNode = node
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
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
                TextField("127.0.0.1:9050", text: $proxyText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        applyProxy()
                    }
            } header: {
                Text("SOCKS Proxy")
            } footer: {
                Text("Route connections through a SOCKS proxy (e.g. Orbot for Tor)")
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
        .onAppear {
            proxyText = nodeManager.proxyAddress
        }
        .onChange(of: proxyText) { _, newValue in
            // Apply when user clears the field
            if newValue.isEmpty && !nodeManager.proxyAddress.isEmpty {
                applyProxy()
            }
        }
        .sheet(isPresented: $showAddNode) {
            AddCustomNodeView { name, url, login, password in
                nodeManager.addCustomNode(name: name, url: url, login: login, password: password)
                Task {
                    await nodeManager.refreshStats()
                }
            }
        }
        .sheet(item: $editingNode) { node in
            EditCustomNodeView(node: node) { name, url, login, password in
                nodeManager.updateCustomNode(oldURL: node.url, name: name, url: url, login: login, password: password)
                // If this was the selected node, reconnect
                if nodeManager.selectedNode.id == node.id {
                    let updatedNode = MoneroNode(name: name, url: url, login: login, password: password)
                    nodeManager.selectNode(updatedNode)
                    walletManager.setNode(url: url, login: login, password: password)
                }
                Task {
                    await nodeManager.refreshStats()
                }
            }
        }
    }

    private func nodeRow(node: MoneroNode) -> some View {
        let isSelected = nodeManager.selectedNode.id == node.id
        let stats = nodeManager.nodeStats[node.url]

        return Button {
            // If auto-select is on, turn it off — manual tap implies manual control
            if nodeManager.autoSelectEnabled {
                nodeManager.autoSelectEnabled = false
            }
            selectNode(node)
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

                        if node.hasCredentials {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(node.url)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Stats row
                    if node.url.contains(".onion") {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(nodeManager.proxyAddress.isEmpty ? Color.gray : Color.green)
                                .frame(width: 8, height: 8)
                            Text("Tor")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if nodeManager.proxyAddress.isEmpty {
                                Text("• Needs proxy")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    } else if let stats = stats {
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
        nodeManager.selectNode(node)
        walletManager.setNode(url: node.url, isTrusted: node.isTrusted, login: node.login, password: node.password)
    }

    private func deleteCustomNode(at offsets: IndexSet) {
        for index in offsets {
            let node = nodeManager.customNodes[index]
            nodeManager.removeCustomNode(node)
        }
    }

    private func applyProxy() {
        nodeManager.setProxy(proxyText)
        walletManager.setProxy(proxyText)
    }
}

// MARK: - Add Custom Node Sheet

struct AddCustomNodeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var login = ""
    @State private var password = ""
    @State private var showAuth = false

    var onAdd: (String, String, String?, String?) -> Void

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("https://node.example.com:18089", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Node Details")
                } footer: {
                    if !name.isEmpty && url.isEmpty {
                        Text("URL is required")
                            .foregroundColor(.red)
                    }
                }

                Section {
                    DisclosureGroup("Authentication", isExpanded: $showAuth) {
                        TextField("Username", text: $login)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    }
                } footer: {
                    Text("Only needed for nodes that require RPC credentials")
                }
            }
            .navigationTitle("Add Custom Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmedLogin = login.trimmingCharacters(in: .whitespaces)
                        let trimmedPassword = password.trimmingCharacters(in: .whitespaces)
                        onAdd(
                            name.trimmingCharacters(in: .whitespaces),
                            url.trimmingCharacters(in: .whitespaces),
                            trimmedLogin.isEmpty ? nil : trimmedLogin,
                            trimmedPassword.isEmpty ? nil : trimmedPassword
                        )
                        dismiss()
                    }
                    .disabled(!isValid)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Edit Custom Node Sheet

struct EditCustomNodeView: View {
    @Environment(\.dismiss) private var dismiss
    let node: MoneroNode
    var onSave: (String, String, String?, String?) -> Void

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var login: String = ""
    @State private var password: String = ""
    @State private var showAuth: Bool = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("https://node.example.com:18089", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Node Details")
                }

                Section {
                    DisclosureGroup("Authentication", isExpanded: $showAuth) {
                        TextField("Username", text: $login)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    }
                } footer: {
                    Text("Only needed for nodes that require RPC credentials")
                }
            }
            .navigationTitle("Edit Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedLogin = login.trimmingCharacters(in: .whitespaces)
                        let trimmedPassword = password.trimmingCharacters(in: .whitespaces)
                        onSave(
                            name.trimmingCharacters(in: .whitespaces),
                            url.trimmingCharacters(in: .whitespaces),
                            trimmedLogin.isEmpty ? nil : trimmedLogin,
                            trimmedPassword.isEmpty ? nil : trimmedPassword
                        )
                        dismiss()
                    }
                    .disabled(!isValid)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                name = node.name
                url = node.url
                login = node.login ?? ""
                password = node.password ?? ""
                showAuth = node.hasCredentials
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack {
        NodeSettingsView()
            .environmentObject(WalletManager())
    }
}
