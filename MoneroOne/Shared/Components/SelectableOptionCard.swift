import SwiftUI

/// Reusable radio-style option row used in pickers (seed format, restore
/// type, etc). Matches the visual language of the "Choose Seed Format"
/// screen: title line with optional recommended badge, subtitle, small
/// detail line, and a checkmark circle on the right. Selected state pulses
/// an orange tint across the card.
struct SelectableOptionCard<ID: Hashable>: View {
    let id: ID
    @Binding var selection: ID
    let title: LocalizedStringResource
    let badge: LocalizedStringResource?
    let subtitle: LocalizedStringResource?
    let detail: LocalizedStringResource?

    init(
        id: ID,
        selection: Binding<ID>,
        title: LocalizedStringResource,
        badge: LocalizedStringResource? = nil,
        subtitle: LocalizedStringResource? = nil,
        detail: LocalizedStringResource? = nil
    ) {
        self.id = id
        self._selection = selection
        self.title = title
        self.badge = badge
        self.subtitle = subtitle
        self.detail = detail
    }

    private var isSelected: Bool { selection == id }

    /// "Polyseed, Recommended. 16 words … . Selected"
    private var spokenLabel: String {
        let badgeText = badge.map { ", " + String(localized: $0) } ?? ""
        let subtitleText = subtitle.map { ". " + String(localized: $0) } ?? ""
        let state = isSelected ? String(localized: "Selected") : String(localized: "Not selected")
        return String(localized: title) + badgeText + subtitleText + ". " + state
    }

    var body: some View {
        Button {
            selection = id
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                        if let badge {
                            Text(badge)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.brand.opacity(0.2))
                                .foregroundColor(.brand)
                                .cornerRadius(4)
                        }
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .brand : .gray)
                    .font(.title2)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.brand.opacity(0.1) : Color(.secondarySystemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.brand : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint("Double tap to select \(String(localized: title))")
    }
}
