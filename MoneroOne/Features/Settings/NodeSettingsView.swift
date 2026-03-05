import SwiftUI

struct NodeSettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @StateObject private var nodeManager = NodeManager()
    @State private var showAddNode = false
    @State private var editingNode: MoneroNode? = nil
    @State private var proxyText: String = ""

    var body: some View {
        List {
            // Nodes section — flat list, default + custom together
            Section {
                Toggle(isOn: $nodeManager.autoSelectEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto Select")
                            .font(.body)
                        Text("Picks fastest reliable node")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.orange)

                ForEach(nodeManager.currentDefaultNodes) { node in
                    nodeRow(node: node)
                }

                ForEach(customClearnetNodes) { node in
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

                Button {
                    showAddNode = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.orange)
                        Text("Add Node")
                    }
                }
            } header: {
                Text(nodeManager.isTestnet ? "Testnet Nodes" : "Nodes")
            }

            // Privacy section
            Section {
                Toggle(isOn: Binding(
                    get: { !proxyText.isEmpty },
                    set: { enabled in
                        if enabled {
                            proxyText = "127.0.0.1:9050"
                            // Auto-select first .onion node
                            if let torNode = NodeManager.torNodes.first {
                                selectNode(torNode)
                            }
                        } else {
                            proxyText = ""
                            // Switch off .onion node if selected
                            if nodeManager.selectedNode.url.contains(".onion") {
                                if let fallback = nodeManager.currentDefaultNodes.first {
                                    selectNode(fallback)
                                }
                            }
                        }
                        applyProxy()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use Tor")
                            .font(.body)
                        Text("Route through Orbot or local Tor proxy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.orange)

                if !proxyText.isEmpty {
                    HStack {
                        Text("Proxy")
                            .foregroundColor(.secondary)
                        Spacer()
                        TextField("127.0.0.1:9050", text: $proxyText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                applyProxy()
                            }
                    }
                }
            } header: {
                Text("Privacy")
            }

            // Tor nodes — only visible when proxy is active
            if !proxyText.isEmpty {
                Section {
                    ForEach(NodeManager.torNodes) { node in
                        nodeRow(node: node)
                    }

                    ForEach(customOnionNodes) { node in
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
                    .onDelete(perform: deleteCustomOnionNode)

                    Button {
                        showAddNode = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.orange)
                            Text("Add Node")
                        }
                    }
                } header: {
                    Text("Tor Nodes")
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
        .onAppear {
            proxyText = nodeManager.proxyAddress
        }
        .onChange(of: proxyText) { _, newValue in
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
                        .lineLimit(1)
                        .truncationMode(.middle)

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
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(uptimeColor(for: stats))
                                    .frame(width: 8, height: 8)
                                if let uptime = stats.uptimeMonth {
                                    Text(String(format: "%.1f%%", uptime))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("--")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if let latency = stats.latencyMs {
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text("\(latency)ms")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else if nodeManager.isLoadingStats {
                                ProgressView()
                                    .scaleEffect(0.5)
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
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .unknown: return .gray
        }
    }

    private var customClearnetNodes: [MoneroNode] {
        nodeManager.customNodes.filter { !$0.url.contains(".onion") }
    }

    private var customOnionNodes: [MoneroNode] {
        nodeManager.customNodes.filter { $0.url.contains(".onion") }
    }

    private func selectNode(_ node: MoneroNode) {
        nodeManager.selectNode(node)
        walletManager.setNode(url: node.url, isTrusted: node.isTrusted, login: node.login, password: node.password)
    }

    private func deleteCustomNode(at offsets: IndexSet) {
        let nodes = customClearnetNodes
        for index in offsets {
            nodeManager.removeCustomNode(nodes[index])
        }
    }

    private func deleteCustomOnionNode(at offsets: IndexSet) {
        let nodes = customOnionNodes
        for index in offsets {
            nodeManager.removeCustomNode(nodes[index])
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
            .navigationTitle("Add Node")
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
