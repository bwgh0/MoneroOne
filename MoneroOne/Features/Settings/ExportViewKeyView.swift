import SwiftUI
import MoneroKit

/// Dedicated screen for sharing the wallet's address + private view key so a
/// second device can be set up as a watch-only mirror. Lives outside the seed
/// backup flow because the view key isn't a spend secret — anyone who
/// already unlocked the app should be able to grab it without re-entering
/// their PIN.
struct ExportViewKeyView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var clipboardClearTask: DispatchWorkItem?

    private let clipboardClearDelay: TimeInterval = 300

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ViewKeyExportCard(
                    title: "Pair Another Device",
                    subtitle: "Share these to set up a view-only wallet — it can watch incoming transactions but cannot spend.",
                    address: walletManager.primaryAddress,
                    viewKey: walletManager.currentViewKey ?? "",
                    restoreHeight: walletManager.restoreHeight,
                    clipboardClearDelay: clipboardClearDelay,
                    clipboardClearTask: $clipboardClearTask
                )

                Text("The private view key reveals every incoming transaction. Share it only with people you trust to watch your balance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
        }
        .navigationTitle("View Key")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { clipboardClearTask?.cancel() }
    }
}

// MARK: - View Key Export Card

/// Renders the address + private view key + restore height triple in a single
/// glass card with per-field copy, a "copy all" button, and a system share
/// sheet.
fileprivate struct ViewKeyExportCard: View {
    let title: String
    let subtitle: String
    let address: String
    let viewKey: String
    let restoreHeight: UInt64
    let clipboardClearDelay: TimeInterval
    @Binding var clipboardClearTask: DispatchWorkItem?

    @State private var addressCopied = false
    @State private var viewKeyCopied = false
    @State private var heightCopied = false
    @State private var dateCopied = false
    @State private var allCopied = false

    private static let genesisDate = Date(timeIntervalSince1970: 1397818193)

    /// Approximate date of the restore-height block. Uses MoneroKit's
    /// `RestoreHeight` lookup table via binary search — same inversion the
    /// sync settings sheet uses — so the displayed date matches the height
    /// the date-based restore flow would produce on another device. The old
    /// naive `genesis + height * 120s` formula drifted years out on modern
    /// heights because real block times vary from the 120s target.
    private var estimatedCreationDate: Date? {
        guard restoreHeight > 0 else { return nil }
        var low = Self.genesisDate
        var high = Date()
        for _ in 0..<20 {
            let mid = Date(timeIntervalSince1970: (low.timeIntervalSince1970 + high.timeIntervalSince1970) / 2)
            let midHeight = UInt64(max(0, RestoreHeight.getHeight(date: mid)))
            if midHeight < restoreHeight {
                low = mid
            } else {
                high = mid
            }
        }
        return low
    }

    private var formattedCreationDate: String? {
        guard let date = estimatedCreationDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var sharePayload: String {
        var lines = [
            "Monero View-Only Wallet",
            "",
            "Address:",
            address,
            "",
            "Private View Key:",
            viewKey
        ]
        if let dateString = formattedCreationDate {
            lines.append(contentsOf: ["", "Creation Date: \(dateString)"])
        }
        if restoreHeight > 0 {
            lines.append("Restore Height: \(restoreHeight)")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ViewKeyField(label: "Primary Address", value: address, copied: addressCopied) {
                copy(address) { addressCopied = $0 }
            }

            ViewKeyField(label: "Private View Key", value: viewKey, copied: viewKeyCopied) {
                copy(viewKey) { viewKeyCopied = $0 }
            }

            if let dateString = formattedCreationDate {
                ViewKeyField(
                    label: "Creation Date",
                    value: dateString,
                    monospace: false,
                    copied: dateCopied
                ) {
                    copy(dateString) { dateCopied = $0 }
                }
            }

            if restoreHeight > 0 {
                ViewKeyField(
                    label: "Restore Height",
                    value: formattedHeight,
                    monospace: false,
                    copied: heightCopied
                ) {
                    copy("\(restoreHeight)") { heightCopied = $0 }
                }
            }

            actionButtons
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color.pink.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .shadow(color: Color.orange.opacity(0.35), radius: 8, y: 3)
                Image(systemName: "eye.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                copy(sharePayload) { allCopied = $0 }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: allCopied ? "checkmark" : "doc.on.doc.fill")
                    Text(allCopied ? "Copied" : "Copy All")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [Color.orange, Color.orange.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityLabel("Copy address, view key, and restore height")

            ShareLink(item: sharePayload) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .glassButtonStyle()
            .accessibilityLabel("Share view-only wallet keys")
        }
    }

    private var formattedHeight: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: restoreHeight)) ?? "\(restoreHeight)"
    }

    private func copy(_ text: String, flag: @escaping (Bool) -> Void) {
        clipboardClearTask?.cancel()
        UIPasteboard.general.string = text

        UINotificationFeedbackGenerator().notificationOccurred(.success)

        flag(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { flag(false) }

        let clearTask = DispatchWorkItem {
            if UIPasteboard.general.string == text {
                UIPasteboard.general.string = ""
            }
        }
        clipboardClearTask = clearTask
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardClearDelay, execute: clearTask)
    }
}

fileprivate struct ViewKeyField: View {
    let label: String
    let value: String
    var monospace: Bool = true
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                Text(value.isEmpty ? "—" : value)
                    .font(monospace ? .system(.footnote, design: .monospaced) : .footnote)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onCopy) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.body)
                        .foregroundStyle(copied ? Color.green : Color.orange)
                        .symbolEffect(.bounce, value: copied)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "\(label) copied" : "Copy \(label)")
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }
}

#Preview {
    NavigationStack {
        ExportViewKeyView()
            .environmentObject(WalletManager())
    }
}
