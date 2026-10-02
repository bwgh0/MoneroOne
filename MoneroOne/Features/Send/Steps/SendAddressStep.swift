import SwiftUI

struct SendAddressStep: View {
    /// The text of the field: an address or an OpenAlias name.
    @Binding var recipientInput: String
    @Binding var showScanner: Bool
    let isConnected: Bool
    let isValidAddress: Bool
    @ObservedObject var lookup: OpenAliasLookupModel
    /// Called with the summary when the field holds a resolved name, else nil.
    let onContinue: (OpenAliasSummary?) -> Void

    @State private var showContent = false
    @State private var dialog: ContinueDialog?
    @FocusState private var fieldFocused: Bool
    /// Set by the card's clear button: the field that comes back gets the cursor.
    @State private var focusFieldOnAppear = false

    /// The dialog that Continue shows on a resolved name (spec 5.2).
    private enum ContinueDialog {
        case changed(OpenAliasSummary, pinnedAt: Date)
        case unsigned(OpenAliasSummary)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    if !isConnected {
                        ErrorBanner(
                            message: String(localized: "No internet connection. Cannot send."),
                            type: .offline
                        )
                        .accessibilityLabel("Offline: no internet connection")
                    }

                    // Address field. A resolved name turns it into the
                    // recipient card, inside the same rounded field.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recipient")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        ZStack {
                            if let resolvedSummary {
                                OpenAliasRecipientCard(summary: resolvedSummary, onClear: clearRecipient)
                                    .padding(.horizontal)
                                    .padding(.vertical, 12)
                                    .transition(.opacity)
                            } else {
                                fieldRow
                                    .padding()
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                        // Validation indicator. On the name path the lookup
                        // row takes its place, in a slot of the same height.
                        if !recipientInput.isEmpty {
                            ZStack(alignment: .leading) {
                                validationRow(isValid: false)
                                    .hidden()
                                    .accessibilityHidden(true)
                                switch input {
                                case .empty:
                                    EmptyView()
                                case .address:
                                    // Typed text shows its row after the typing delay.
                                    if lookup.phase == .address {
                                        validationRow(isValid: isValidAddress)
                                            .transition(.opacity)
                                    }
                                case .name, .reserved, .invalidName:
                                    if let resolvedSummary {
                                        OpenAliasResolvedLines(summary: resolvedSummary)
                                            .transition(.opacity)
                                    } else {
                                        OpenAliasStatusRow(lookup: lookup)
                                    }
                                }
                            }
                        }
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        Button {
                            showScanner = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "qrcode.viewfinder")
                                Text("Scan QR")
                            }
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.brand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .glassButtonStyle()
                        .accessibilityLabel("Scan QR code")

                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                recipientInput = clipboard
                                lookup.submit(clipboard)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.clipboard")
                                Text("Paste")
                            }
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.brand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .glassButtonStyle()
                        .accessibilityLabel("Paste address from clipboard")
                    }
                }
                .padding()
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
            }

            // Continue button
            Button(action: continueTapped) {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(canContinue ? .brand : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!canContinue)
            .padding()
            .accessibilityLabel("Continue")
            .accessibilityHint(continueHint)
        }
        .navigationTitle("Send XMR")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
        }
        .alert(
            dialogTitle,
            isPresented: Binding(
                get: { dialog != nil },
                set: { if !$0 { dialog = nil } }
            ),
            presenting: dialog
        ) { dialog in
            Button("Cancel", role: .cancel) {}
            switch dialog {
            case .changed(let summary, _):
                Button("Use New Address") { onContinue(summary) }
            case .unsigned(let summary):
                Button("Continue Anyway") { onContinue(summary) }
            }
        } message: { dialog in
            switch dialog {
            case .changed(let summary, let pinnedAt):
                let paidOn = DateFormatter.localizedString(from: pinnedAt, dateStyle: .medium, timeStyle: .none)
                if let recipientName = summary.recipientName {
                    Text("The address for \(recipientName) (\(summary.name.display)) is different from the address you paid on \(paidOn). Check the new address with the recipient.",
                         comment: "Address Changed dialog: the record name, the OpenAlias name, then the date of the last payment")
                } else {
                    Text("The address for \(summary.name.display) is different from the address you paid on \(paidOn). Check the new address with the recipient.")
                }
            case .unsigned(let summary):
                Text("\(summary.name.display) has no DNSSEC signature. A DNS server between you and the owner of the name can change this answer. Check the address with the recipient before you send.")
            }
        }
    }

    /// The text field, with the lookup spinner and the clear button.
    private var fieldRow: some View {
        HStack {
            // Typed text goes to the lookup from the binding: when
            // two keystrokes land in one frame, SwiftUI drops an
            // onChange call, and the lookup kept a part of the name.
            TextField("Enter XMR address or OpenAlias", text: Binding(
                get: { recipientInput },
                set: { newValue in
                    recipientInput = newValue
                    lookup.textChanged(newValue)
                }
            ))
                .font(.system(.caption, design: .monospaced))
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onSubmit { lookup.submit(recipientInput) }
                .accessibilityIdentifier("send.addressField")
                .accessibilityLabel("Recipient address or OpenAlias name")

            if isLookingUpName {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Looking up \(lookup.name?.display ?? "")…"))
                    .transition(.opacity)
            }

            if !recipientInput.isEmpty {
                Button {
                    lookup.cancel()
                    recipientInput = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                // Gray like the clear button of the recipient card, which
                // takes its place: the tint made it a pale orange.
                .buttonStyle(.plain)
                .accessibilityLabel("Clear address")
            }
        }
        .onAppear {
            guard focusFieldOnAppear else { return }
            focusFieldOnAppear = false
            fieldFocused = true
        }
    }

    private var isLookingUpName: Bool {
        guard case .name = input else { return false }
        return lookup.isLooking
    }

    /// The card's clear button: the empty field comes back, with the cursor.
    private func clearRecipient() {
        lookup.cancel()
        focusFieldOnAppear = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            recipientInput = ""
        }
    }

    /// The existing "Valid address" / "Invalid address" row.
    private func validationRow(isValid: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isValid ? .green : .red)
            Text(isValid ? "Valid address" : "Invalid address")
                .font(.caption)
                .foregroundStyle(isValid ? .green : .red)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isValid ? "Valid address" : "Invalid address")
    }

    private var input: RecipientInput {
        OpenAlias.classify(recipientInput)
    }

    /// The lookup result, when it belongs to the name in the field.
    private var resolvedSummary: OpenAliasSummary? {
        guard case .name(let name) = input, let summary = lookup.summary,
              summary.name.query == name.query else { return nil }
        return summary
    }

    private var canContinue: Bool {
        guard isConnected else { return false }
        switch input {
        case .address: return isValidAddress
        case .name: return resolvedSummary != nil
        case .empty, .reserved, .invalidName: return false
        }
    }

    private var continueHint: Text {
        if canContinue { return Text("Proceed to enter amount") }
        if case .name = input, lookup.isLooking { return Text("Wait for the name lookup to finish") }
        return Text("Enter a valid address first")
    }

    private var dialogTitle: Text {
        switch dialog {
        case .changed: return Text("Address Changed")
        case .unsigned: return Text("Name Not Signed")
        case nil: return Text(verbatim: "")
        }
    }

    /// Continue on a resolved name shows one dialog at most: a changed pin
    /// first, since its message also asks for a check, then a name with no
    /// DNSSEC signature.
    private func continueTapped() {
        guard case .name = input else {
            onContinue(nil)
            return
        }
        guard let summary = resolvedSummary else { return }
        if case .changed(let pinnedAt) = summary.pin {
            dialog = .changed(summary, pinnedAt: pinnedAt)
        } else if summary.dnssec == .off {
            dialog = .unsigned(summary)
        } else {
            onContinue(summary)
        }
    }
}
