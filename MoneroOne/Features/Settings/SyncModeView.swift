import SwiftUI

enum SyncMode: String, CaseIterable {
    case lite = "Lite Mode"
    case privacy = "Privacy Mode"

    var description: String {
        switch self {
        case .lite:
            return "Fast sync using Light Wallet Server. Your view key is shared with the server."
        case .privacy:
            return "Full privacy sync using remote node. Slower but your keys stay local."
        }
    }

    var icon: String {
        switch self {
        case .lite: return "bolt.fill"
        case .privacy: return "shield.fill"
        }
    }
}

struct SyncModeView: View {
    @AppStorage("syncMode") private var syncMode: String = SyncMode.lite.rawValue

    var body: some View {
        List {
            Section {
                ForEach(SyncMode.allCases, id: \.self) { mode in
                    Button {
                        syncMode = mode.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode.icon)
                                .font(.title2)
                                .foregroundColor(mode == .lite ? .orange : .blue)
                                .frame(width: 40)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.rawValue)
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            if syncMode == mode.rawValue {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            } footer: {
                Text("Lite Mode is recommended for most users. Privacy Mode offers maximum privacy but requires more bandwidth and time.")
            }
        }
        .navigationTitle("Sync Mode")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SyncModeView()
    }
}
