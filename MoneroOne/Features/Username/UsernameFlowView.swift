import SwiftUI

struct UsernameFlowView: View {
  @EnvironmentObject private var wallets: WalletManager
  @ObservedObject var store: UsernameStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var stage: Stage = .welcome
  @State private var input = ""
  @State private var error: String?
  @State private var claimed: UsernameBinding?
  @State private var appeared = false
  @State private var task: Task<Void, Never>?
  @FocusState private var focused: Bool
  let walletKey: String
  let walletSession: UUID
  let walletName: String
  let walletEmoji: String
  let network: String
  private enum Stage { case welcome, choose, confirm, claiming, revealed, noFreeClaim }

  private var valid: Bool { (try? UsernameRules.normalize(input)) != nil }
  /// This wallet's saved claim: the flow stays on it until a check settles it.
  private var resumesPendingClaim: Bool {
    store.state.pending.map { $0.walletKey == walletKey && $0.network == network } ?? false
  }
  private var currentWallet: Bool {
    wallets.isUnlocked && wallets.walletSessionId == walletSession
      && wallets.usernameWalletKey == walletKey
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 24) {
          if stage == .welcome {
            AnimatedWalletIcon(size: 120, symbol: "at").padding(.top, 45).padding(.bottom, 28)
            Text("Get Your Username.").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("A short username people can use to pay you.").foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
            primary("Choose My Username") {
              stage = .choose
              focused = true
            }
            Button("Not Now") { dismiss() }.foregroundStyle(.secondary).frame(minHeight: 44)
          } else if stage == .noFreeClaim {
            Image(systemName: "at").font(.system(size: 70, weight: .light)).foregroundStyle(.brand)
              .padding(.top, 60)
            Text("A free username isn't available on this phone.").font(.title2.weight(.semibold))
              .multilineTextAlignment(.center)
            primary("Done") { dismiss() }
          } else if stage == .choose {
            Text("Choose Your Username").font(.largeTitle.bold()).frame(
              maxWidth: .infinity, alignment: .leading
            ).padding(.top, 30)
            HStack(spacing: 2) {
              Text(verbatim: "@").foregroundStyle(.brand)
              TextField("username", text: $input)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.asciiCapable).focused($focused).submitLabel(.continue)
                .onSubmit {
                  if valid {
                    focused = false
                    stage = .confirm
                  }
                }
                .onChange(of: input) { _, value in
                  if value.count > 15 { input = String(value.prefix(15)) }
                  error = nil
                }
            }
            .font(.system(size: 22, weight: .medium)).lineLimit(1)
            .padding(20).background(
              Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            Text(validationMessage).font(.footnote).foregroundStyle(
              valid ? Color.secondary : Color.brand
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            walletNote
            primary("Continue", disabled: !valid) {
              focused = false
              stage = .confirm
            }
          } else {
            if stage == .revealed {
              Text("It's Yours.").font(.largeTitle.bold()).padding(.top, 32)
            }
            UsernameCard(
              handle: claimed?.displayHandle ?? input,
              externalAddress: claimed?.externalAddress
                ?? ((try? UsernameRules.normalize(input)) ?? input.lowercased()) + "@monero.one",
              still: stage == .claiming, claiming: stage == .claiming
            )
            .padding(.top, stage == .revealed ? 10 : 35)
            .scaleEffect(stage == .revealed && !appeared && !reduceMotion ? 0.8 : 1)
            .opacity(stage == .revealed && !appeared ? 0 : 1)
            walletNote
            if stage == .claiming {
              Text("username.claiming").foregroundStyle(.secondary).accessibilityAddTraits(
                .updatesFrequently)
            } else if stage == .revealed, let binding = claimed {
              UsernameActions(binding: binding)
              primary("Done") { dismiss() }
            } else {
              Text("Usernames are permanent.").font(.subheadline.weight(.medium))
              // The production terms and device gates are pending. A local
              // development build must not pretend this is public registration.
              Text("This is a local development claim.").font(.footnote).foregroundStyle(.secondary)
              primary("Claim @\(input)") { claim() }
            }
          }
          if let error {
            Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier(
              "username.error")
          }
        }.padding(.horizontal, 24).padding(.bottom, 32)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle(stage == .welcome ? "" : "Your Username").navigationBarTitleDisplayMode(
        .inline
      )
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if (stage == .choose || stage == .confirm) && !resumesPendingClaim {
            Button("Back", systemImage: "chevron.left") {
              error = nil
              stage = stage == .confirm ? .choose : .welcome
            }
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          if stage != .claiming { Button("Done") { dismiss() } }
        }
      }
      .interactiveDismissDisabled(stage == .claiming)
      .onAppear {
        if let pending = store.state.pending, pending.walletKey == walletKey,
          pending.network == network
        {
          input = pending.displayHandle
          stage = .confirm
        }
      }
      .onChange(of: wallets.walletSessionId) { _, _ in dismiss() }
      .onChange(of: wallets.isUnlocked) { _, unlocked in if !unlocked { dismiss() } }
    }
  }
  private var validationMessage: String {
    guard !input.isEmpty else { return String(localized: "3–15 characters. Letters, numbers and _.") }
    do {
      _ = try UsernameRules.normalize(input)
      return String(localized: "3–15 characters. Availability is checked when you claim.")
    } catch { return UsernameRules.message(for: error) }
  }
  private var walletNote: some View {
    VStack(spacing: 4) {
      Text("Payments go to").font(.footnote).foregroundStyle(.secondary)
      Text(verbatim: "\(walletEmoji) \(walletName)").font(.subheadline.weight(.medium))
        .multilineTextAlignment(.center)
    }.padding(.vertical, 12)
  }
  private func primary(_ title: LocalizedStringKey, disabled: Bool = false, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 54) }
      .buttonStyle(.plain).foregroundStyle(Color(.systemBackground))
      .background(Color.primary.opacity(disabled ? 0.25 : 1), in: Capsule()).disabled(disabled)
  }
  private func claim() {
    guard stage == .confirm, currentWallet else {
      error = UsernameFailure.walletChanged.localizedDescription
      return
    }
    guard let configuration = UsernameConfiguration.current else {
      error = UsernameFailure.notConfigured.localizedDescription
      return
    }
    stage = .claiming
    error = nil
    task = Task { @MainActor in
      do {
        let binding = try await UsernameRegistry(configuration: configuration).claim(
          displayHandle: input,
          walletKey: walletKey, network: network, store: store,
          makeSubaddress: {
            guard currentWallet, let address = await wallets.createSubaddress(), currentWallet
            else { throw UsernameFailure.walletChanged }
            return address.address
          },
          sign: { message, address in
            try wallets.signUsername(message, subaddress: address, expectedSession: walletSession)
          }, isCurrentWallet: { currentWallet })
        guard currentWallet else {
          dismiss()
          return
        }
        claimed = binding
        appeared = false
        stage = .revealed
        await Task.yield()
        withAnimation(
          reduceMotion ? .easeIn(duration: 0.2) : .spring(response: 0.65, dampingFraction: 0.75)
        ) { appeared = true }
        HapticFeedback.shared.transactionSuccess()
      } catch UsernameFailure.noFreeClaim { stage = .noFreeClaim } catch {
        // A failure the app does not name (the network, say) gets one plain message, not the system's.
        self.error =
          (error as? UsernameFailure)?.localizedDescription
          ?? String(localized: "The claim could not be completed. Please try again.")
        stage = .confirm
      }
    }
  }
}

struct UsernameDetailsView: View {
  let binding: UsernameBinding
  let walletName: String
  let walletEmoji: String
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 28) {
          UsernameCard(handle: binding.displayHandle, externalAddress: binding.externalAddress)
            .padding(.top, 35)
          VStack(spacing: 5) {
            Text("Payments go to").font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: "\(walletEmoji) \(walletName)").font(.subheadline.weight(.medium))
          }
          UsernameActions(binding: binding)
        }.padding(.horizontal, 24).padding(.bottom, 35)
      }
      .navigationTitle("Your Username").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
    .presentationBackground(.ultraThinMaterial)
  }
}

private struct UsernameActions: View {
  let binding: UsernameBinding
  @Environment(\.colorScheme) private var colorScheme
  @State private var share = false
  @State private var copied = false
  @State private var shareItems: [Any] = []
  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Menu {
          Button("\(binding.shortName) · Monero One") { copy(binding.shortName) }
          Button("\(binding.externalAddress) · Other apps") { copy(binding.externalAddress) }
          Button("Share link") { copy(binding.shareURL.absoluteString) }
        } label: {
          Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 54)
        }
        .glassButtonStyle()
        Button {
          prepareShare()
        } label: {
          Label("Share", systemImage: "square.and.arrow.up").frame(
            maxWidth: .infinity, minHeight: 54)
        }
        .glassButtonStyle()
      }.tint(.brand)
      if copied { Text("Copied").font(.footnote).foregroundStyle(.secondary) }
    }
    .sheet(isPresented: $share) {
      ShareSheet(items: shareItems)
    }
  }
  @MainActor private func prepareShare() {
    let renderer = ImageRenderer(
      content: UsernameCard(
        handle: binding.displayHandle, externalAddress: binding.externalAddress, still: true
      )
      .frame(width: 1000, height: 600).padding(40).environment(\.colorScheme, colorScheme))
    renderer.scale = 1
    shareItems = ["\(binding.shortName)\n\(binding.externalAddress)", binding.shareURL]
    if let image = renderer.uiImage { shareItems.insert(image, at: 0) }
    share = true
  }
  private func copy(_ value: String) {
    UIPasteboard.general.string = value
    copied = true
    HapticFeedback.shared.buttonPress()
  }
}
