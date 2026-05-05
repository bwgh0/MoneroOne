import Foundation
import Combine
import MoneroKit

/// Transient orchestrator for a Trezor reconnect window.
///
/// The iPhone primary wallet runs as a normal watch-only wallet2 instance
/// (SOFTWARE / watch_only=1) that scans blocks 24/7 with no device. When
/// the user wants to reveal sent transactions or send funds, TrezorSession
/// brings the device online, opens a SIDECAR wallet2 instance bound to
/// the Trezor (TREZOR / watch_only=0), runs the wallet2 cold-sign blob
/// exchange between the two, optionally signs and broadcasts a tx, then
/// tears the sidecar down and resumes the primary.
///
/// One session = one reconnect window. Don't reuse — create fresh each
/// time so transient state can't leak between attempts.
@MainActor
final class TrezorSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connectingDevice
        case openingSidecar
        case syncingSidecar(progress: Double)
        case exchangingBlobs
        case signing
        case broadcasting
        case complete
        case failed(message: String)
    }

    enum SessionError: Error, LocalizedError {
        case notHardwareWallet
        case missingBinding
        case missingDeviceWalletId
        case deviceUnreachable
        case sidecarOpenFailed(String)
        case sidecarSyncFailed(String)
        case keyImageSyncFailed(String)
        case signingFailed(String)
        case broadcastFailed(String)
        case userCancelled

        var errorDescription: String? {
            switch self {
            case .notHardwareWallet:    return "This wallet is not bound to a hardware device."
            case .missingBinding:       return "Trezor binding metadata is missing."
            case .missingDeviceWalletId: return "Sidecar wallet identifier is missing — wallet may have been created before hardware support."
            case .deviceUnreachable:    return "Could not reach the Trezor. Make sure it is powered on and in range."
            case .sidecarOpenFailed(let m):  return "Failed to open device-bound wallet: \(m)"
            case .sidecarSyncFailed(let m):  return "Failed to sync device-bound wallet: \(m)"
            case .keyImageSyncFailed(let m): return "Key image sync failed: \(m)"
            case .signingFailed(let m):      return "Trezor declined or failed to sign: \(m)"
            case .broadcastFailed(let m):    return "Broadcast failed: \(m)"
            case .userCancelled:        return "Session cancelled."
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    private let walletInfo: WalletInfo
    private let binding: TrezorBinding
    private let networkType: MoneroKit.NetworkType
    private let trezorManager: TrezorManager

    /// The primary watch-only wallet running on the iPhone. Owned by
    /// WalletManager — the session only borrows it to pause refresh and
    /// drive blob exchange.
    private weak var primaryWallet: MoneroWallet?

    /// The transient device-bound wallet2 instance. Created in
    /// `openSidecar()`, torn down in `tearDown()`.
    private var sidecarWallet: MoneroWallet?

    init(
        walletInfo: WalletInfo,
        primaryWallet: MoneroWallet,
        trezorManager: TrezorManager,
        networkType: MoneroKit.NetworkType
    ) throws {
        guard case .hardware(let hw) = walletInfo.source,
              case .trezor(let binding) = hw else {
            throw SessionError.notHardwareWallet
        }
        guard walletInfo.deviceWalletId != nil else {
            throw SessionError.missingDeviceWalletId
        }
        self.walletInfo = walletInfo
        self.binding = binding
        self.primaryWallet = primaryWallet
        self.trezorManager = trezorManager
        self.networkType = networkType
    }

    // MARK: - Public flows

    /// Bring the device online and pull spent-output state into the
    /// primary wallet so outgoing transactions decode correctly. Used by
    /// the "Reveal sent transactions" banner.
    func reconnect() async throws {
        try await runPrelude()
        try await exchangeKeyImages()
        try await tearDown()
        phase = .complete
    }

    /// Bring the device online, sync key images, sign + broadcast.
    /// NOT YET IMPLEMENTED — needs wallet2 unsigned-tx blob bindings
    /// in MoneroKit before this can be wired up. Throws so callers
    /// fail fast rather than silently no-op.
    func send(to address: String, amount: Decimal, priority: SendPriority = .default, memo: String? = nil) async throws -> String {
        try await runPrelude()
        try await exchangeKeyImages()
        phase = .signing
        defer { Task { try? await tearDown() } }
        throw SessionError.signingFailed("Cold-sign send not yet wired up — pending unsigned-tx blob bindings in MoneroKit.")
    }

    /// Cancel an in-flight session. Safe to call from any phase.
    func cancel() async {
        try? await tearDown()
        phase = .failed(message: SessionError.userCancelled.localizedDescription ?? "cancelled")
    }

    // MARK: - Phases

    /// Steps shared by every flow: pause primary, connect device, open
    /// sidecar, fast-forward sidecar to primary's tip.
    private func runPrelude() async throws {
        guard let primary = primaryWallet else {
            throw SessionError.sidecarOpenFailed("primary wallet released")
        }

        phase = .connectingDevice
        await primary.pauseSyncAsync()
        try await connectDevice()

        phase = .openingSidecar
        try await openSidecar()

        phase = .syncingSidecar(progress: 0)
        try await fastForwardSidecar(toPrimaryHeight: primary.walletHeight)
    }

    private func connectDevice() async throws {
        // TODO: peripheral-targeted connect. For the v0 sketch we rely on
        // TrezorManager being already connected — the UI flow brings up
        // BLE/THP before instantiating the session. Future revision will
        // route through `binding.peripheralUUID` for fast reconnect.
        guard case .bridgeRunning = trezorManager.state else {
            throw SessionError.deviceUnreachable
        }
    }

    private func openSidecar() async throws {
        guard walletInfo.deviceWalletId != nil else {
            throw SessionError.missingDeviceWalletId
        }
        // Sketch only. Sidecar opening needs a MoneroKit initializer
        // that takes (a) an explicit walletId so the cache lives at
        // `MoneroKit/<deviceWalletId>/...` next to the primary, and
        // (b) `MoneroWallet.trezor(deviceName:)` credentials so the
        // wallet is born device-bound. The existing `create()` /
        // `createWatchOnly()` pair don't support either — Phase 6 will
        // extend MoneroWallet (the app wrapper) with `createFromDevice`
        // that drops into `Kit(wallet: .trezor(deviceName:), ...)`.
        throw SessionError.sidecarOpenFailed("Phase 6 work — sidecar initializer not yet wired.")
    }

    private func fastForwardSidecar(toPrimaryHeight target: UInt64) async throws {
        // For the sketch: the sidecar starts its own refresh and we wait
        // until its height meets or exceeds the primary's. Real impl will
        // poll `walletHeight` at intervals, surface progress, time out if
        // stalled. Skip the actual await for now — real wiring goes here.
        _ = target
    }

    private func exchangeKeyImages() async throws {
        guard let primary = primaryWallet, let sidecar = sidecarWallet else {
            throw SessionError.keyImageSyncFailed("missing wallet ref")
        }
        phase = .exchangingBlobs

        // 1. Cold (primary) hands its outputs to the device-bound sidecar.
        guard let outputsBlob = await primary.exportOutputsUR() else {
            throw SessionError.keyImageSyncFailed("primary exportOutputsUR returned nil")
        }
        let imported = await sidecar.importOutputsUR(outputsBlob)
        guard imported else {
            throw SessionError.keyImageSyncFailed("sidecar importOutputsUR rejected blob")
        }

        // 2. Sidecar generates key images via the device, hands them back.
        guard let keyImagesBlob = await sidecar.exportKeyImagesUR() else {
            throw SessionError.keyImageSyncFailed("sidecar exportKeyImagesUR returned nil")
        }
        let consumed = await primary.importKeyImagesUR(keyImagesBlob)
        guard consumed else {
            throw SessionError.keyImageSyncFailed("primary importKeyImagesUR rejected blob")
        }
    }

    private func tearDown() async throws {
        if let sidecar = sidecarWallet {
            await sidecar.stopAsync()
            sidecarWallet = nil
        }
        // Primary's refresh will be resumed by WalletManager once the
        // session reports `.complete` — keeping the resume in WalletManager
        // means the session can fail/cancel without leaving state confused.
    }
}

