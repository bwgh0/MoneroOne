import SwiftUI

/// Reusable radio-style option row used in pickers (seed format, restore
/// type, etc). Matches the visual language of the "Choose Seed Format"
/// screen: title line with optional recommended badge, subtitle, small
/// detail line, and a checkmark circle on the right. Selected state pulses
/// an orange tint across the card.
struct SelectableOptionCard<ID: Hashable>: View {
    let id: ID
    @Binding var selection: ID
    let title: String
    let badge: String?
    let subtitle: String?
    let detail: String?

    init(
        id: ID,
        selection: Binding<ID>,
        title: String,
        badge: String? = nil,
        subtitle: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self._selection = selection
        self.title = title
        self.badge = badge
        self.subtitle = subtitle
        self.detail = detail
    }

    private var isSelected: Bool { selection == id }

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
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
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
                    .foregroundColor(isSelected ? .orange : .gray)
                    .font(.title2)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.orange.opacity(0.1) : Color(.secondarySystemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.orange : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(badge.map { ", \($0)" } ?? "")\(subtitle.map { ". \($0)" } ?? ""). \(isSelected ? "Selected" : "Not selected")")
        .accessibilityHint("Double tap to select \(title)")
    }
}
