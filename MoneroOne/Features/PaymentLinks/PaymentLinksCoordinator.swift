import Foundation
import SwiftUI
import MoneroKit

/// Takes claim links in (Universal Link, `moneroone://` link, a paste or
/// scan into Send) and opens the claim sheet when the app can show it.
///
/// Every good link is saved as a received record in the Keychain first, so
/// a link that arrives while the app is locked, or before any wallet exists,
/// waits on the balance card ("to claim") and opens after unlock, create or
/// restore.
@MainActor
final class PaymentLinksCoordinator: ObservableObject {
    static let shared = PaymentLinksCoordinator()

    /// What the claim sheet shows.
    struct Presentation: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A received link: claim it.
            case claim
            /// A link this device sent.
            case own
        }

        let id: String
        let kind: Kind
        /// Claim as soon as the check finds the link ready: the user
        /// already tapped Claim on the balance card or the link's row.
        var autoClaim = false
    }

    /// Waiting to show, or showing.
    @Published var presentation: Presentation?
    /// A link that could not be read. Shown as an alert.
    @Published var linkError: String?

    private let store: EnvelopeStore

    init(store: EnvelopeStore = .shared) {
        self.store = store
    }

    /// Handles `url` when it is a claim link, good or bad. Returns false for
    /// every other URL, which then goes to the `monero:` handler.
    /// `activeAddress`: the active wallet's primary address. A link whose
    /// envelope is that wallet is the user's own.
    @discardableResult
    func handle(url: URL, networkType: MoneroKit.NetworkType, activeAddress: String? = nil) -> Bool {
        handle(text: url.absoluteString, networkType: networkType, activeAddress: activeAddress)
    }

    /// Same, for text pasted or scanned into the Send recipient field.
    @discardableResult
    func handle(text: String, networkType: MoneroKit.NetworkType, activeAddress: String? = nil) -> Bool {
        guard EnvelopeLink.looksLikeClaimLink(text) else { return false }
        do {
            let link = try EnvelopeLink.parse(text)
            try open(link, networkType: networkType, activeAddress: activeAddress)
        } catch let error as EnvelopeLink.ParseError {
            linkError = error.message
        } catch {
            linkError = EnvelopeSession.message(for: error)
        }
        return true
    }

    /// Opens a saved record: Claim on the balance card, a link to claim in
    /// Activity's Links filter, or Reclaim on our expired link.
    /// `autoClaim`: claim a received link once its check finds it ready.
    func present(_ record: EnvelopeRecord, autoClaim: Bool = false) {
        let kind: Presentation.Kind = record.role == .sent ? .own : .claim
        presentation = Presentation(id: record.id, kind: kind, autoClaim: autoClaim && kind == .claim)
    }

    func dismiss() {
        presentation = nil
    }

    // MARK: - Private

    private func open(_ link: EnvelopeLink, networkType: MoneroKit.NetworkType, activeAddress: String?) throws {
        // Our own link: never save it as received.
        if store.record(id: link.id, role: .sent) != nil {
            presentation = Presentation(id: link.id, kind: .own)
            return
        }
        guard let address = EnvelopeSecret.address(for: link.words, networkType: networkType),
              MoneroKit.Kit.isValid(address: address, networkType: networkType) else {
            throw EnvelopeLink.ParseError.incomplete
        }
        if let activeAddress, !activeAddress.isEmpty, activeAddress == address {
            linkError = String(localized: "This is your own link. It holds this wallet's own keys, so there is nothing to claim.")
            return
        }
        if var existing = store.record(id: link.id, role: .received) {
            // The same link again. Keep what we learned.
            if existing.address != address {
                // Same id, different secret: a different link. Keep the
                // first; a link id is meant to be unique.
                throw EnvelopeLink.ParseError.incomplete
            }
            // The secret is kept until a claim is mined; put it back so a
            // claim that never confirmed can run again.
            if existing.link == nil {
                existing.setSecret(from: link)
            }
            // Only v1 links carry an amount and an expiry; a v2 record keeps
            // what its checks learned.
            if link.format == .v1 {
                existing.amount = link.amount
                existing.expiry = link.expiry
            }
            try store.save(existing)
        } else {
            var record = EnvelopeRecord(
                id: link.id,
                role: .received,
                words: nil,
                address: address,
                restoreHeight: link.restoreHeight,
                amount: link.amount,
                expiry: link.expiry,
                createdAt: Date(),
                status: .created
            )
            record.setSecret(from: link)
            try store.save(record)
        }
        presentation = Presentation(id: link.id, kind: .claim)
    }
}

// MARK: - Presenting

/// Shows the claim sheet over the app once the wallet is unlocked. Waits for
/// sheets that hold no work to close (`closesForPaymentLink`), the same way a
/// `monero:` link opens Send.
struct PaymentLinkClaimPresenter: ViewModifier {
    @ObservedObject var walletManager: WalletManager
    @ObservedObject var coordinator: PaymentLinksCoordinator
    @State private var shown: PaymentLinksCoordinator.Presentation?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: presentIfReady)
            .onChange(of: coordinator.presentation) { _, _ in presentIfReady() }
            .onChange(of: walletManager.isUnlocked) { _, unlocked in
                if unlocked { presentIfReady() } else { shown = nil }
            }
            .onChange(of: walletManager.hasWallet) { _, _ in presentIfReady() }
            .sheet(item: $shown, onDismiss: {
                // A lock closes the sheet; the link opens again after unlock.
                if walletManager.isUnlocked { coordinator.dismiss() }
            }) { presentation in
                PaymentLinkClaimSheet(presentation: presentation)
                    .environmentObject(walletManager)
            }
            .alert(
                "Can't Open Link",
                isPresented: Binding(
                    get: { coordinator.linkError != nil && walletManager.isUnlocked },
                    set: { if !$0 { coordinator.linkError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(coordinator.linkError ?? "")
            }
    }

    private func presentIfReady() {
        guard let presentation = coordinator.presentation else {
            shown = nil
            return
        }
        guard walletManager.isUnlocked, walletManager.hasWallet, shown != presentation else { return }
        guard Self.isSheetShowing else {
            shown = presentation
            return
        }
        NotificationCenter.default.post(name: .paymentLinkClosesSheets, object: nil)
        Task { @MainActor in
            var waited = 0
            while Self.isSheetShowing, waited < 30 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard coordinator.presentation == presentation, walletManager.isUnlocked else { return }
            shown = presentation
        }
    }

    @MainActor
    private static var isSheetShowing: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }
}

extension View {
    /// Root of the app: claim links open their sheet here.
    func presentsPaymentLinkClaims(walletManager: WalletManager) -> some View {
        modifier(PaymentLinkClaimPresenter(walletManager: walletManager, coordinator: .shared))
    }
}
