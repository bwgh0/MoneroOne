import SwiftUI
import ContactsUI

// Send To, phase B: the Contacts sheet of Send's field, New Contact and
// Edit Contact, and the contact's card in the field.

/// The inside of a contact row: the monogram, the name, and the OpenAlias
/// name or the 8…8 address. The chosen contact shows the check.
struct ContactRowContent: View {
    let contact: Contact
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            RecipientMonogram(initials: contact.initials)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: contact.name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                ContactDestinationText(contact: contact)
            }

            Spacer(minLength: 0)

            if isSelected {
                WalletRowCheck(isSelected: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The second line: an OpenAlias name as text, an address in 8…8 mono.
private struct ContactDestinationText: View {
    let contact: Contact

    var body: some View {
        Group {
            if contact.kind == .openAlias {
                Text(verbatim: contact.destination)
                    .font(.subheadline)
            } else {
                Text(verbatim: contact.shortDestination)
                    .font(.caption)
                    .monospaced()
            }
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }
}

/// A contact as a tappable row, the switcher's row style without the ring.
struct ContactRowButton: View {
    let contact: Contact
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ContactRowContent(contact: contact, isSelected: isSelected)
                .padding(16)
                .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: contact.spokenLabel))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("contacts.row")
    }
}

/// The preview shape of a row's touch and hold menu.
private var contactRowShape: AnyShape {
    if #available(iOS 26.0, *) {
        return AnyShape(Capsule())
    }
    return AnyShape(RoundedRectangle(cornerRadius: 12))
}

// MARK: - Contacts sheet

/// Contacts, A to Z, with search and +. A tap picks the contact and closes
/// the sheet. Touch and hold: Edit Contact, Copy Address, Delete Contact.
struct ContactsSheet: View {
    /// The contact in Send's field: its row shows the check.
    let selectedId: UUID?
    let onPick: (Contact) -> Void

    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var store = ContactStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showNew = false
    @State private var editing: Contact?
    @State private var deleting: Contact?

    var body: some View {
        NavigationStack {
            Group {
                if store.contacts.isEmpty {
                    ScrollView {
                        ContactsEmptyCard()
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                } else {
                    list
                        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search"))
                        .overlay {
                            if shown.isEmpty {
                                ContentUnavailableView.search(text: search)
                            }
                        }
                }
            }
            .navigationTitle("Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Contact")
                    .accessibilityIdentifier("contacts.new")
                }
            }
        }
        // Search added to a stack that is already up went to the bottom
        // bar: the first contact builds the stack again, with Search on top.
        .id(store.contacts.isEmpty)
        .sheet(isPresented: $showNew) {
            ContactEditor(mode: .new(destination: ""))
                .environmentObject(walletManager)
        }
        .sheet(item: $editing) { contact in
            ContactEditor(mode: .edit(contact))
                .environmentObject(walletManager)
        }
        .deleteContactAlert(contact: $deleting)
    }

    private var shown: [Contact] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? store.contacts : ContactMatch.matches(text, in: store.contacts)
    }

    private var list: some View {
        List {
            ForEach(shown) { contact in
                ContactRowButton(contact: contact, isSelected: contact.id == selectedId) {
                    HapticFeedback.shared.buttonPress()
                    onPick(contact)
                    dismiss()
                }
                .contentShape(.contextMenuPreview, contactRowShape)
                .contextMenu {
                    Button {
                        editing = contact
                    } label: {
                        Label("Edit Contact", systemImage: "pencil")
                    }
                    Button {
                        UIPasteboard.general.string = contact.destination
                        HapticFeedback.shared.softTick()
                    } label: {
                        Label(contact.kind == .openAlias ? "Copy OpenAlias" : "Copy Address", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleting = contact
                    } label: {
                        Label("Delete Contact", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleting = contact
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .accessibilityAction(named: Text("Edit Contact")) { editing = contact }
                .accessibilityAction(named: Text("Delete Contact")) { deleting = contact }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// "No Contacts" in a rounded card, as the mockup shows it.
private struct ContactsEmptyCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No Contacts")
                .font(.headline)
            Text("Contacts you save show here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Delete alert

private struct DeleteContactAlert: ViewModifier {
    @Binding var contact: Contact?
    var onDeleted: () -> Void = {}

    func body(content: Content) -> some View {
        content.alert(
            "Delete Contact?",
            isPresented: Binding(get: { contact != nil }, set: { if !$0 { contact = nil } }),
            presenting: contact
        ) { contact in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                ContactStore.shared.delete(id: contact.id)
                onDeleted()
            }
        } message: { _ in
            Text("Your transactions stay in History.")
        }
    }
}

extension View {
    /// The one delete alert of the Contacts sheet, its menu and Edit Contact.
    func deleteContactAlert(contact: Binding<Contact?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(DeleteContactAlert(contact: contact, onDeleted: onDeleted))
    }
}

// MARK: - New Contact and Edit Contact

/// New Contact (Cancel, Save) and Edit Contact (Cancel, Done, Delete
/// Contact last). One field takes an address or an OpenAlias name, checked
/// as Send's field checks it.
struct ContactEditor: View {
    enum Mode {
        /// The destination comes filled in from a sent transaction.
        case new(destination: String)
        case edit(Contact)
    }

    let mode: Mode

    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lookup = OpenAliasLookupModel()
    @State private var name: String
    @State private var destination: String
    @State private var showPicker = false
    @State private var deleting: Contact?
    @FocusState private var nameFocused: Bool

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .new(let destination):
            _name = State(initialValue: "")
            _destination = State(initialValue: destination)
        case .edit(let contact):
            _name = State(initialValue: contact.name)
            _destination = State(initialValue: contact.destination)
        }
    }

    private var editedContact: Contact? {
        if case .edit(let contact) = mode { return contact }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    RecipientMonogram(initials: initials, diameter: 88)
                        .padding(.top, 8)

                    nameCard

                    destinationSection

                    if let contact = editedContact {
                        Button {
                            deleting = contact
                        } label: {
                            Text("Delete Contact")
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("contact.delete")
                    }
                }
                .padding()
            }
            .navigationTitle(editedContact == nil ? Text("New Contact") : Text(verbatim: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editedContact == nil ? "Save" : "Done") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("contact.save")
                }
            }
        }
        .onAppear {
            lookup.network = walletManager.networkType
            if !destination.isEmpty { lookup.submit(destination) }
            if editedContact == nil, destination.isEmpty { nameFocused = true }
        }
        .onChange(of: destination) { _, newValue in
            lookup.textChanged(newValue)
        }
        .background(ContactNamePicker(isPresented: $showPicker) { picked in
            name = picked
        })
        .deleteContactAlert(contact: $deleting) { dismiss() }
    }

    private var initials: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : OpenAlias.initials(recipientName: trimmed, display: "")
    }

    /// The name, and "Choose from Contacts" under it, in one rounded card.
    private var nameCard: some View {
        VStack(spacing: 0) {
            TextField("Name", text: $name)
                .textContentType(.name)
                .focused($nameFocused)
                .padding(16)
                .accessibilityIdentifier("contact.name")
            Divider()
                .padding(.leading, 16)
            Button {
                showPicker = true
            } label: {
                Text("Choose from Contacts")
                    .foregroundStyle(.brand)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Copies a name from your iPhone's contacts")
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var input: RecipientInput {
        OpenAlias.classify(destination)
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Address or OpenAlias")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("", text: $destination, axis: .vertical)
            .font(isName ? .body : .system(.callout, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Address or OpenAlias")
            .accessibilityIdentifier("contact.destination")

            status
        }
    }

    private var isName: Bool {
        if case .name = input { return true }
        return false
    }

    /// Send's status line: "Valid address" or "Invalid address", or the
    /// OpenAlias lookup's lines.
    @ViewBuilder
    private var status: some View {
        switch input {
        case .empty:
            EmptyView()
        case .address:
            if lookup.phase == .address {
                AddressValidationRow(isValid: walletManager.isValidAddress(destination))
            }
        case .name, .reserved, .invalidName:
            if let resolvedSummary {
                OpenAliasResolvedLines(summary: resolvedSummary)
            } else {
                OpenAliasStatusRow(lookup: lookup)
            }
        }
    }

    private var resolvedSummary: OpenAliasSummary? {
        guard case .name(let name) = input, let summary = lookup.summary,
              summary.name.query == name.query else { return nil }
        return summary
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch input {
        case .address: return walletManager.isValidAddress(destination.trimmingCharacters(in: .whitespacesAndNewlines))
        case .name: return resolvedSummary != nil
        case .empty, .reserved, .invalidName: return false
        }
    }

    private func save() {
        guard canSave else { return }
        HapticFeedback.shared.buttonPress()
        if var contact = editedContact {
            contact.name = name
            contact.destination = destination
            ContactStore.shared.update(contact)
        } else {
            ContactStore.shared.add(name: name, destination: destination)
        }
        dismiss()
    }
}

/// The existing "Valid address" / "Invalid address" row of Send's field.
struct AddressValidationRow: View {
    let isValid: Bool

    var body: some View {
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
}

// MARK: - Choose from Contacts

/// The system contact picker. It runs outside the app, so it needs no
/// Contacts permission; only the chosen name comes back.
struct ContactNamePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // One picker: updates can repeat before the presentation starts.
        guard isPresented, !coordinator.isShowing, host.presentedViewController == nil else { return }
        coordinator.isShowing = true
        let picker = CNContactPickerViewController()
        picker.delegate = coordinator
        DispatchQueue.main.async {
            host.present(picker, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactNamePicker
        var isShowing = false

        init(parent: ContactNamePicker) {
            self.parent = parent
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            if let name = Self.name(of: contact) { parent.onPick(name) }
            isShowing = false
            parent.isPresented = false
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            isShowing = false
            parent.isPresented = false
        }

        /// The full name, else the company.
        static func name(of contact: CNContact) -> String? {
            var parts: [String] = []
            if contact.isKeyAvailable(CNContactGivenNameKey), !contact.givenName.isEmpty { parts.append(contact.givenName) }
            if contact.isKeyAvailable(CNContactFamilyNameKey), !contact.familyName.isEmpty { parts.append(contact.familyName) }
            if !parts.isEmpty { return parts.joined(separator: " ") }
            if contact.isKeyAvailable(CNContactOrganizationNameKey), !contact.organizationName.isEmpty { return contact.organizationName }
            return nil
        }
    }
}

// MARK: - Send's field

/// A contact in the recipient field: the monogram, the name and the
/// OpenAlias name or 8…8 address, with the clear button.
struct ContactRecipientCard: View {
    let contact: Contact
    let onClear: () -> Void
    /// A tap on the card opens the Contacts sheet, where its row shows the check.
    var onOpenContacts: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                RecipientMonogram(initials: contact.initials)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: contact.name)
                        .font(.headline)
                        .lineLimit(1)
                    ContactDestinationText(contact: contact)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenContacts)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-12)
            .accessibilityLabel("Clear recipient")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: contact.spokenLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows your contacts")
        .accessibilityAction(.default) { onOpenContacts() }
        .accessibilityAction(named: Text("Clear recipient"), onClear)
        .accessibilityIdentifier("send.contactCard")
    }
}
