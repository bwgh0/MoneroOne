import SwiftUI

struct NodeSettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @StateObject private var nodeManager = NodeManager()
    @State private var showAddNode = false
    @State private var showAddProxy = false
    @State private var editingNode: MoneroNode? = nil
    @State private var editingProxy: ProxyEntry? = nil
    @State private var torEnabled: Bool = false

    var body: some View {
        List {
            // MARK: - Nodes Section
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

                // Clearnet default nodes
                ForEach(nodeManager.currentDefaultNodes) { node in
                    nodeRow(node: node)
                }

                // Custom clearnet nodes
                ForEach(customClearnetNodes) { node in
                    customNodeRow(node: node)
                }
                .onDelete(perform: deleteCustomClearnetNode)

                // .onion default nodes
                ForEach(NodeManager.torNodes) { node in
                    nodeRow(node: node)
                        .disabled(!torEnabled)
                        .opacity(torEnabled ? 1.0 : 0.4)
                }

                // Custom .onion nodes
                ForEach(customOnionNodes) { node in
                    customNodeRow(node: node)
                        .disabled(!torEnabled)
                        .opacity(torEnabled ? 1.0 : 0.4)
                }
                .onDelete(perform: deleteCustomOnionNode)

                addNodeButton
            } header: {
                Text(nodeManager.isTestnet ? "Testnet Nodes" : "Nodes")
            }

            // MARK: - Tor Proxy Section
            Section {
                Toggle(isOn: $torEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use Tor Proxy")
                            .font(.body)
                        Text("Route traffic through SOCKS5 proxy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.orange)

                if torEnabled {
                    ForEach(NodeManager.defaultProxies) { proxy in
                        proxyRow(proxy: proxy)
                    }

                    ForEach(nodeManager.customProxies) { proxy in
                        customProxyRow(proxy: proxy)
                    }
                    .onDelete(perform: deleteCustomProxy)

                    Button {
                        showAddProxy = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.orange)
                            Text("Add Proxy")
                        }
                    }
                }
            } header: {
                Text("Tor Proxy")
            } footer: {
                Text("Requires Orbot or a local Tor daemon")
            }
        }
        .navigationTitle(nodeManager.isTestnet ? "Remote Node (Testnet)" : "Remote Node")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.2), value: torEnabled)
        .refreshable {
            await nodeManager.refreshStats()
        }
        .task {
            await nodeManager.refreshStats()
        }
        .onAppear {
            torEnabled = !nodeManager.proxyAddress.isEmpty
        }
        .onChange(of: torEnabled) { _, enabled in
            handleTorToggle(enabled)
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
        .sheet(isPresented: $showAddProxy) {
            AddCustomProxyView { name, address in
                nodeManager.addCustomProxy(name: name, address: address)
                Task {
                    await nodeManager.checkProxyReachability(for: address)
                }
            }
        }
        .sheet(item: $editingProxy) { proxy in
            EditCustomProxyView(proxy: proxy) { name, address in
                let oldAddress = proxy.address
                nodeManager.updateCustomProxy(oldAddress: oldAddress, name: name, address: address)
                if nodeManager.selectedProxyAddress == oldAddress {
                    nodeManager.selectProxy(ProxyEntry(name: name, address: address))
                    walletManager.setProxy(address)
                }
                Task {
                    await nodeManager.checkProxyReachability(for: address)
                }
            }
        }
    }

    // MARK: - Components

    private var addNodeButton: some View {
        Button {
            showAddNode = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.orange)
                Text("Add Node")
            }
        }
    }

    private func customNodeRow(node: MoneroNode) -> some View {
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

    private func nodeRow(node: MoneroNode) -> some View {
        let isSelected = nodeManager.selectedNode.id == node.id
        let stats = nodeManager.nodeStats[node.url]
        let isOnion = node.url.contains(".onion")

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
                    if isOnion {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(torEnabled ? selectedProxyStatusColor : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(torEnabled ? "Tor" : "Requires Tor")
                                .font(.caption2)
                                .foregroundColor(.secondary)
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

    // MARK: - Helpers

    private func uptimeColor(for stats: NodeStats) -> Color {
        switch stats.uptimeColor {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .unknown: return .gray
        }
    }

    private var selectedProxyStatusColor: Color {
        reachabilityColor(nodeManager.selectedProxyReachable)
    }

    private func proxyReachabilityColor(for address: String) -> Color {
        reachabilityColor(nodeManager.proxyReachability[address])
    }

    private func reachabilityColor(_ reachable: Bool?) -> Color {
        switch reachable {
        case .none: return .gray
        case .some(true): return .green
        case .some(false): return .red
        }
    }

    private func customProxyRow(proxy: ProxyEntry) -> some View {
        HStack {
            proxyRow(proxy: proxy)
            Button {
                editingProxy = proxy
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
    }

    private func proxyRow(proxy: ProxyEntry) -> some View {
        let isSelected = nodeManager.selectedProxyAddress == proxy.address

        return Button {
            nodeManager.selectProxy(proxy)
            walletManager.setProxy(proxy.address)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(proxy.name)
                        .foregroundColor(.primary)
                    Text(proxy.address)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(proxyReachabilityColor(for: proxy.address))
                            .frame(width: 8, height: 8)
                        Text("SOCKS5")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.orange)
                }
            }
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

    private func handleTorToggle(_ enabled: Bool) {
        if enabled {
            // Apply selected proxy (or default) — do NOT disable auto-select or force .onion node
            let proxy = nodeManager.allProxies.first { $0.address == nodeManager.selectedProxyAddress }
                ?? nodeManager.allProxies.first
            if let proxy = proxy {
                nodeManager.selectProxy(proxy)
                walletManager.setProxy(proxy.address)
            }
            Task {
                await nodeManager.checkAllProxyReachability()
            }
        } else {
            nodeManager.setProxy("")
            nodeManager.proxyReachability.removeAll()
            // Save proxy to UserDefaults without restarting — the setNode()
            // call below (if needed) will pick up the cleared proxy and do
            // a single wallet restart instead of two.
            walletManager.saveProxy("")
            // Fall back to clearnet node if currently on .onion
            if nodeManager.selectedNode.url.contains(".onion") {
                if let fallback = nodeManager.currentDefaultNodes.first {
                    selectNode(fallback) // single restart via setNode()
                }
            } else {
                // Not on .onion — still need one restart to drop the proxy
                walletManager.setProxy("")
            }
        }
    }

    private func deleteCustomClearnetNode(at offsets: IndexSet) {
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

    private func deleteCustomProxy(at offsets: IndexSet) {
        let proxies = nodeManager.customProxies
        for index in offsets {
            nodeManager.removeCustomProxy(proxies[index])
        }
        walletManager.setProxy(nodeManager.proxyAddress)
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

// MARK: - Edit Custom Proxy Sheet

struct EditCustomProxyView: View {
    @Environment(\.dismiss) private var dismiss
    let proxy: ProxyEntry
    var onSave: (String, String) -> Void

    @State private var name: String = ""
    @State private var address: String = ""

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("127.0.0.1:9050", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Proxy Details")
                } footer: {
                    Text("Enter the SOCKS5 proxy address as host:port")
                }
            }
            .navigationTitle("Edit Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            name.trimmingCharacters(in: .whitespaces),
                            address.trimmingCharacters(in: .whitespaces)
                        )
                        dismiss()
                    }
                    .disabled(!isValid)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                name = proxy.name
                address = proxy.address
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Add Custom Proxy Sheet

struct AddCustomProxyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""

    var onAdd: (String, String) -> Void

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("127.0.0.1:9050", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Proxy Details")
                } footer: {
                    Text("Enter the SOCKS5 proxy address as host:port")
                }
            }
            .navigationTitle("Add Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(
                            name.trimmingCharacters(in: .whitespaces),
                            address.trimmingCharacters(in: .whitespaces)
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

#Preview {
    NavigationStack {
        NodeSettingsView()
            .environmentObject(WalletManager())
    }
}
