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
  @State private var focusOnAppear = false
  @State private var task: Task<Void, Never>?
  @State private var edge: UsernameCard.ClaimEdge?
  /// The reveal's landing: 1 once the title has arrived, 2 once the buttons
  /// have, 3 once the moment has ended.
  @State private var arrived = 0
  @FocusState private var focused: Bool
  let walletKey: String
  let walletSession: UUID
  let walletName: String
  let walletEmoji: String
  let network: String
  private enum Stage {
    case welcome, choose, confirm, claiming, landing, revealed, noFreeClaim
    /// The steps on the stack above Welcome while this stage shows. The
    /// claim and its result stay on the confirm step, so the card stays put.
    var stackPath: [Step] {
      switch self {
      case .welcome: return []
      case .choose: return [.choose]
      case .confirm, .claiming, .landing, .revealed, .noFreeClaim: return [.choose, .confirm]
      }
    }
    /// The stage after the back button or the edge swipe pops the stack to
    /// `path`. Pushes go through the stage, so only a shorter path changes it.
    func popped(to path: [Step]) -> Stage {
      guard path.count < stackPath.count else { return self }
      switch path.last {
      case nil: return .welcome
      case .choose: return .choose
      case .confirm: return self
      }
    }
    /// The confirm step's pages that Reduce Motion cross-fades as a whole.
    /// The claim keeps the confirm page, so the card stays in place.
    var fadedPage: Int {
      switch self {
      case .revealed: return 1
      case .noFreeClaim: return 2
      default: return 0
      }
    }
  }
  /// A step pushed on the flow's navigation stack. Welcome is the root.
  private enum Step: Hashable { case choose, confirm }

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
    // Choose and Confirm are pushes, so the system back button and the edge
    // swipe go back one step, as in Send.
    NavigationStack(path: stepPath) {
      page(titled: false) { welcomeContent }
        .navigationDestination(for: Step.self) { step in
          switch step {
          case .choose:
            page(titled: true) { chooseContent }
              .onAppear {
                guard focusOnAppear else { return }
                focusOnAppear = false
                focused = true
              }
          case .confirm:
            // The claim and its result have no way back: no back button,
            // and so no edge swipe. A saved claim has none either.
            page(titled: true) { confirmContent }
              .navigationBarBackButtonHidden(stage != .confirm || resumesPendingClaim)
          }
        }
    }
    .interactiveDismissDisabled(stage == .claiming || stage == .landing)
    .onAppear {
      if let pending = store.state.pending, pending.walletKey == walletKey,
        pending.network == network
      {
        input = pending.displayHandle
        jump(to: .confirm)
      }
    }
    // A flow that closes mid-claim must not leave Home's update held.
    .onDisappear { store.releaseUpdates() }
    .onChange(of: wallets.walletSessionId) { _, _ in dismiss() }
    .onChange(of: wallets.isUnlocked) { _, unlocked in if !unlocked { dismiss() } }
  }
  /// No Done in the bar while the claim and its moment run. It comes back
  /// with Home's update, after the shine: the bar's rebuild must not stop it.
  private var showsDone: Bool {
    switch stage {
    case .claiming, .landing: return false
    case .revealed: return arrived >= 3
    default: return true
    }
  }
  private func page<Content: View>(titled: Bool, @ViewBuilder content: () -> Content)
    -> some View
  {
    ScrollView {
      VStack(spacing: 24) { content() }.padding(.horizontal, 24).padding(.bottom, 32)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle(!titled ? "" : "Your Username").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if showsDone { Button("Done") { dismiss() } }
      }
    }
  }
  @ViewBuilder private var welcomeContent: some View {
    AnimatedWalletIcon(size: 120, symbol: "at").padding(.top, 45).padding(.bottom, 28)
    Text("Get Your Username.").font(.largeTitle.bold()).multilineTextAlignment(.center)
    Text("A short username people can use to pay you.").foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
    primary("Choose My Username") {
      focusOnAppear = true
      goForward(to: .choose)
    }
    Button("Not Now") { dismiss() }.foregroundStyle(.secondary).frame(minHeight: 44)
  }
  @ViewBuilder private var chooseContent: some View {
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
            goForward(to: .confirm)
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
      goForward(to: .confirm)
    }
  }
  /// Confirm, the claim, its result and noFreeClaim: one step that changes
  /// in place, like Send's status step. With Reduce Motion the result and
  /// noFreeClaim replace the page in one cross-fade, so the card never
  /// slides down under the new title.
  /// A pushed page does not take the flow's `withAnimation`, so the step
  /// animates its own stage changes.
  private var confirmContent: some View {
    ZStack(alignment: .top) {
      VStack(spacing: 24) { confirmStage }
        .id(reduceMotion ? stage.fadedPage : 0)
        .transition(.opacity)
    }
    .animation(stageAnimation, value: stage)
    // `arrive`; its 0.1 s delay is in the landing's own waits.
    .animation(.easeOut(duration: 0.4), value: arrived)
  }
  /// The reveal's layout, with room for the title above the card. Without
  /// Reduce Motion the card moves there while the ring closes; with it,
  /// the page cross-fades to it at the reveal.
  private var showsRevealLayout: Bool {
    stage == .revealed || (stage == .landing && !reduceMotion)
  }
  /// `arrive`: fade in and rise 20 pt. Reduce Motion: a fade only.
  private func arrival(_ step: Int) -> some ViewModifier {
    UsernameArrive(isShown: arrived >= step, reduceMotion: reduceMotion)
  }
  @ViewBuilder private var confirmStage: some View {
    if stage == .noFreeClaim {
      Image(systemName: "at").font(.system(size: 70, weight: .light)).foregroundStyle(.brand)
        .padding(.top, 60)
      Text("A free username isn't available on this phone.").font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
      primary("Done") { dismiss() }
    } else {
      if showsRevealLayout {
        // Hidden until it arrives, so the card does not move again.
        Text("It's Yours.").font(.largeTitle.bold()).padding(.top, 32)
          .modifier(arrival(1)).transition(.identity)
      }
      UsernameCard(
        handle: claimed?.displayHandle ?? input,
        externalAddress: claimed?.externalAddress
          ?? ((try? UsernameRules.normalize(input)) ?? input.lowercased()) + "@monero.one",
        // The tilt starts after the moment, not with the pop.
        still: stage == .claiming || stage == .landing || (stage == .revealed && arrived < 3),
        edge: stage == .confirm ? nil : edge, celebrates: stage == .revealed,
        awaitsClaim: true
      )
      .padding(.top, showsRevealLayout ? 10 : 35)
      walletNote
      if stage == .claiming || stage == .landing {
        // It fades where it is while the card moves, so the note passes no text.
        Text("username.claiming").foregroundStyle(.secondary).opacity(stage == .claiming ? 1 : 0)
          .accessibilityAddTraits(.updatesFrequently)
      } else if stage == .confirm {
        Text("Usernames are permanent.").font(.subheadline.weight(.medium))
        #if DEBUG
        // A development build must not pretend this is public registration.
        Text("This is a local development claim.").font(.footnote).foregroundStyle(.secondary)
        #endif
        VStack(spacing: 12) {
          primary("Claim @\(input)") { claim() }
          termsNote
        }
      }
      // The buttons are laid out, hidden, as soon as the result is in, so
      // the pop does not wait for them to be built.
      if stage != .confirm, let binding = claimed {
        Group {
          UsernameActions(binding: binding)
          primary("Done") { dismiss() }
        }
        .modifier(arrival(2)).allowsHitTesting(arrived >= 2).transition(.identity)
      }
    }
    if let error {
      Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier(
        "username.error")
    }
  }
  private var validationMessage: String {
    guard !input.isEmpty else { return String(localized: "3–15 characters. Letters, numbers and _.") }
    do {
      _ = try UsernameRules.normalize(input)
      return String(localized: "3–15 characters. Availability is checked when you claim.")
    } catch { return UsernameRules.message(for: error) }
  }
  /// The agreement the claim records (terms version in `UsernameRegistry`).
  /// The link opens in the browser, like the app's other monero.one links.
  private var termsNote: some View {
    Text("By claiming, you confirm you are 18 or older and agree to the [Username Terms](https://monero.one/username-terms).")
      .font(.footnote).foregroundStyle(.secondary).tint(.brand)
      .multilineTextAlignment(.center)
      .accessibilityAddTraits(.isLink)
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
    // A plain button takes taps on its text only. The whole capsule is the target.
    Button(action: action) {
      Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 54)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain).foregroundStyle(Color(.systemBackground))
    .background(Color.primary.opacity(disabled ? 0.25 : 1), in: Capsule()).disabled(disabled)
  }

  // MARK: - Navigation

  /// The stack follows `stage`. A pop by the back button or the edge swipe
  /// writes the shorter path back as the stage one step earlier, and clears
  /// the error, as the old Back button did.
  private var stepPath: Binding<[Step]> {
    Binding(
      get: { stage.stackPath },
      set: { path in
        let next = stage.popped(to: path)
        guard next != stage else { return }
        error = nil
        stage = next
      })
  }
  /// A push, or the claim's start inside the confirm step.
  private func goForward(to next: Stage) { move(to: next) }
  /// Send's springs for a change inside the confirm step: `stepForward` into
  /// the claim, `celebrate` for the reveal, `settle` for the landing,
  /// noFreeClaim and the return to Confirm.
  private func spring(into next: Stage) -> Spring {
    switch next {
    case .claiming: return Spring(response: 0.3, dampingRatio: 0.85)
    case .revealed: return Spring(response: 0.5, dampingRatio: 0.7)
    default: return Spring(response: 0.4, dampingRatio: 0.8)
    }
  }
  /// The confirm step's motion into the current stage. Reduce Motion: a cross-fade.
  private var stageAnimation: Animation {
    reduceMotion ? .easeInOut(duration: 0.35) : .spring(spring(into: stage))
  }
  /// A push or a pop brings the system's own motion. A change inside the
  /// confirm step runs with that step's `stageAnimation`.
  /// `done` runs when the motion has ended.
  private func move(to next: Stage, also: () -> Void = {}, done: @escaping () -> Void = {}) {
    let inPlace = next.stackPath == stage.stackPath
    also()
    stage = next
    guard inPlace else { return done() }
    let motion = reduceMotion ? 0.35 : spring(into: next).settlingDuration
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(motion))
      done()
    }
  }
  /// Opens the flow on the confirm step with no push animation (a saved claim).
  private func jump(to next: Stage) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { stage = next }
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
    // Home redraws once, after the result has animated in, not under the
    // claim edge or the reveal. The claim still saves at the same moments.
    store.holdUpdates()
    let started = Date()
    edge = UsernameCard.ClaimEdge(start: started)
    arrived = 0
    goForward(to: .claiming)
    error = nil
    task = Task { @MainActor in
      do {
        let binding = try await UsernameRegistry(configuration: configuration).claim(
          displayHandle: input,
          walletKey: walletKey, network: network, store: store,
          makeSubaddress: {
            guard currentWallet else { throw UsernameFailure.walletChanged }
            let address = try await wallets.createUsernameSubaddress(expectedSession: walletSession)
            guard currentWallet else { throw UsernameFailure.walletChanged }
            return address
          },
          sign: { message, address in
            try await wallets.signUsername(message, subaddress: address, expectedSession: walletSession)
          },
          claimKey: { try wallets.usernameClaimKey(expectedSession: walletSession) },
          ownsSubaddress: { address in
            guard currentWallet else { return false }
            return try await wallets.ownsUsernameSubaddress(address, expectedSession: walletSession)
          },
          isCurrentWallet: { currentWallet })
        claimed = binding
        // The build-up: the edge runs one full lap at least, also when the
        // registry answers at once.
        let lap = UsernameCard.ClaimEdge.lap - Date().timeIntervalSince(started)
        if lap > 0 { try? await Task.sleep(for: .seconds(lap)) }
        guard currentWallet else {
          store.releaseUpdates()
          dismiss()
          return
        }
        await land()
      } catch UsernameFailure.noFreeClaim {
        move(to: .noFreeClaim, done: store.releaseUpdates)
      } catch {
        // A failure the app does not name (the network, say) gets one plain message, not the system's.
        let message =
          (error as? UsernameFailure)?.localizedDescription
          ?? String(localized: "The claim could not be completed. Please try again.")
        // `settle`, as Send's return to Review.
        move(to: .confirm, also: { self.error = message }, done: store.releaseUpdates)
      }
    }
  }
  /// The claim's moment, for a new name and a restored one. The ring closes
  /// while the card moves under the title's room; then the card pops with
  /// the success haptic, and the title and the buttons arrive. Home redraws
  /// once the shine has ended.
  private func land() async {
    edge?.close = Date()
    stage = .landing
    // The pop must meet the closed ring: no timer slack.
    try? await Task.sleep(for: .seconds(UsernameCard.ClaimEdge.closing), tolerance: .zero)
    // `celebrate`, as Send's success.
    stage = .revealed
    HapticFeedback.shared.transactionSuccess()
    try? await Task.sleep(for: .seconds(0.2))
    arrived = 1
    try? await Task.sleep(for: .seconds(0.15))
    arrived = 2
    // The shine runs 1.2 s from the pop; with Reduce Motion the last fade ends sooner.
    try? await Task.sleep(for: .seconds(reduceMotion ? 0.4 : 0.85))
    arrived = 3
    store.releaseUpdates()
  }
}

/// `arrive` for the reveal's title and buttons: fade in and rise 20 pt.
/// Reduce Motion: a fade only.
private struct UsernameArrive: ViewModifier {
  let isShown: Bool
  let reduceMotion: Bool
  func body(content: Content) -> some View {
    content.opacity(isShown ? 1 : 0).offset(y: isShown || reduceMotion ? 0 : 20)
  }
}

/// The @name screen: the wallet's own name, its hold, and Retire Name.
struct UsernameDetailsView: View {
  let binding: UsernameBinding
  let walletName: String
  let walletEmoji: String
  let walletSession: UUID
  @ObservedObject var store: UsernameStore
  @EnvironmentObject private var wallets: WalletManager
  @Environment(\.dismiss) private var dismiss
  @State private var confirmsRetire = false
  @State private var retiring = false
  @State private var error: String?

  private var nameState: UsernameNameState { store.nameState(for: binding) }
  private var currentWallet: Bool {
    wallets.isUnlocked && wallets.walletSessionId == walletSession
      && wallets.usernameWalletKey == binding.walletKey
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 28) {
          if let reason = nameState.heldReason {
            ErrorBanner(message: Self.holdText(reason, name: binding.displayHandle), type: .held)
              .padding(.top, 16)
          }
          UsernameCard(handle: binding.displayHandle, externalAddress: binding.externalAddress)
            .padding(.top, nameState.heldReason == nil ? 35 : 0)
          VStack(spacing: 5) {
            Text("Payments go to").font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: "\(walletEmoji) \(walletName)").font(.subheadline.weight(.medium))
          }
          UsernameActions(binding: binding)
          if nameState.retireAllowed { retireRow }
        }.padding(.horizontal, 24).padding(.bottom, 35)
      }
      .navigationTitle("Your Username").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
    .presentationBackground(.ultraThinMaterial)
    .interactiveDismissDisabled(retiring)
    .task { await checkStatus() }
  }

  /// The red Retire Name row: one confirmation at the row, progress and
  /// errors in place.
  private var retireRow: some View {
    VStack(spacing: 4) {
      Button(role: .destructive) {
        error = nil
        confirmsRetire = true
      } label: {
        HStack(spacing: 8) {
          if retiring { ProgressView().tint(.brand) }
          Text("Retire Name")
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
      }
      .disabled(retiring)
      .accessibilityIdentifier("username.retire")
      .accessibilityLabel(retiring ? Text("Retiring @\(binding.displayHandle)") : Text("Retire Name"))
      .accessibilityHint(Text("Retires @\(binding.displayHandle) after you confirm"))
      .confirmationDialog(
        Text("Retire @\(binding.displayHandle)?"), isPresented: $confirmsRetire, titleVisibility: .visible
      ) {
        Button("Retire", role: .destructive) { retire() }
        Button("Cancel", role: .cancel) {}
      } message: {
        if let date = nameState.nextFreeClaim {
          Text(
            "Payments to @\(binding.displayHandle) stop working within about 2 hours, and nobody can claim it again. You can claim a new name starting \(Self.claimDay(date).formatted(date: .long, time: .omitted))."
          )
        } else {
          Text(
            "Payments to @\(binding.displayHandle) stop working within about 2 hours, and nobody can claim it again."
          )
        }
      }
      if let error {
        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
          .accessibilityIdentifier("username.retire.error")
      }
    }
  }

  /// The gray On hold row's text, one sentence pair per reason.
  static func holdText(_ reason: UsernameHoldReason, name: String) -> String {
    switch reason {
    case .order:
      return String(
        localized: "@\(name) is on hold because of a court order. Payments to @\(name) don't work while it's on hold.")
    case .notice:
      return String(
        localized:
          "@\(name) is on hold because of a notice we received. Payments to @\(name) don't work while it's on hold.")
    case .sanctions:
      return String(
        localized: "@\(name) is on hold because of sanctions rules. Payments to @\(name) don't work while it's on hold.")
    case .terms:
      return String(
        localized:
          "@\(name) is on hold because of a breach of the Username Terms. Payments to @\(name) don't work while it's on hold."
      )
    }
  }

  /// The first local day that starts at or after the next free claim, as a
  /// long date: "starting" that day never names a day too early.
  static func claimDay(_ date: Date, calendar: Calendar = .current) -> Date {
    let start = calendar.startOfDay(for: date)
    return start < date ? calendar.date(byAdding: .day, value: 1, to: start) ?? date : start
  }

  /// The registry's state of the name when the screen opens. A hold shows
  /// its row. Only a retire that the registrar signed forgets the name and
  /// closes the screen; a 404 or an unsigned answer keeps it.
  private func checkStatus() async {
    guard let configuration = UsernameConfiguration.current else { return }
    let forgot = await UsernameRegistry(configuration: configuration).checkOnOpen(
      binding, store: store, isRetiring: { retiring })
    if forgot { dismiss() }
  }

  private func retire() {
    guard !retiring else { return }
    guard currentWallet else {
      error = UsernameFailure.walletChanged.localizedDescription
      return
    }
    guard let configuration = UsernameConfiguration.current else {
      error = UsernameFailure.notConfigured.localizedDescription
      return
    }
    retiring = true
    error = nil
    Task { @MainActor in
      defer { retiring = false }
      do {
        try await UsernameRegistry(configuration: configuration).retire(
          binding, store: store,
          sign: { message, address in
            try await wallets.signUsername(message, subaddress: address, expectedSession: walletSession)
          },
          isCurrentWallet: { currentWallet })
        dismiss()
      } catch UsernameFailure.held {
        // A hold showed up on the name: its row shows. An order or sanctions
        // hold also removes the Retire row; notice and terms holds keep it.
      } catch {
        self.error =
          (error as? UsernameFailure)?.localizedDescription
          ?? String(localized: "The username service couldn't complete the request. Please try again.")
      }
    }
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
