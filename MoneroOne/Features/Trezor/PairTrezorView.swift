import SwiftUI

/// Multi-wallet-aware Trezor pairing flow.
///
/// Replaces the single-wallet `TrezorScanView` from
/// `feature/trezor-safe7`. The new flow plugs into `AddWalletView`'s
/// navigation path the same way `RestoreViewKeyView` does — connect
/// over BLE/THP, pull `MoneroGetWatchKey` from the device, then call
/// `WalletManager.pairTrezorWallet(...)` to land a watch-only wallet
/// tagged `WalletSource.hardware(.trezor(...))`.
///
/// Watch-key extraction itself is the open problem. Two ways:
///   1. Open a transient TREZOR-bound wallet2 instance via
///      `MoneroWallet.createFromDevice`, read its primary address and
///      `secretViewKey`, close it. Reuses wallet2's protocol logic at
///      the cost of leaving a small TREZOR-mode cache on disk that we
///      need to clean up.
///   2. Talk THP directly: `THPChannel.sendProtobuf(messageType: 542,
///      data: MoneroGetWatchKey{...})` and parse the `MoneroWatchKey`
///      response. Avoids wallet2 entirely but needs hand-coded
///      protobuf for two messages (or pull in swift-protobuf).
///
/// Going with (1) for the first pass because it reuses the
/// already-tested THP protocol path inside wallet2 and the small on-
/// disk cache is the same `deviceWalletId`-keyed sidecar we already
/// need for reconnect sessions — pairing just bootstraps it.
struct PairTrezorView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    var isAddingWallet: Bool = false
    var existingPin: String? = nil

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Pair Trezor")
                .font(.title2.weight(.semibold))
            Text("UI coming next chunk. Wiring in place — `WalletManager.pairTrezorWallet(...)` is ready to call once the watch-key extraction path is decided.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .navigationTitle("Pair Trezor")
        .navigationBarTitleDisplayMode(.inline)
    }
}
