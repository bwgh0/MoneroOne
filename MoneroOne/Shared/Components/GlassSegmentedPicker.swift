import SwiftUI

/// A glass-style segmented picker with a sliding capsule indicator.
/// Uses iOS 26 liquid glass effect when available, falls back to material on older versions.
struct GlassSegmentedPicker<T: Hashable & CaseIterable>: View where T.AllCases: RandomAccessCollection {
    @Binding var selection: T
    let label: (T) -> String

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(T.allCases), id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selection == item ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if selection == item {
                                Capsule()
                                    .fill(.clear)
                                    .liquidGlassIfAvailable()
                                    .matchedGeometryEffect(id: "selector", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .liquidGlassContainerIfAvailable(cornerRadius: 14)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selection)
    }
}

/// Compact variant with smaller text and padding for dashboard cards
struct CompactGlassSegmentedPicker<T: Hashable & CaseIterable>: View where T.AllCases: RandomAccessCollection {
    @Binding var selection: T
    let label: (T) -> String

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(T.allCases), id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(selection == item ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selection == item {
                                Capsule()
                                    .fill(.clear)
                                    .liquidGlassIfAvailable()
                                    .matchedGeometryEffect(id: "selector", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .liquidGlassContainerIfAvailable(cornerRadius: 10)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selection)
    }
}

// MARK: - iOS Version Compatibility

private extension View {
    /// Applies liquid glass effect on iOS 26+, falls back to thin material on older versions
    @ViewBuilder
    func liquidGlassIfAvailable() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Applies liquid glass container on iOS 26+, falls back to regular material on older versions
    @ViewBuilder
    func liquidGlassContainerIfAvailable(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

#Preview("Standard") {
    struct PreviewWrapper: View {
        enum TimeRange: String, CaseIterable {
            case day = "24H"
            case week = "1W"
            case month = "1M"
            case year = "1Y"
        }

        @State private var selection: TimeRange = .week

        var body: some View {
            VStack(spacing: 40) {
                GlassSegmentedPicker(selection: $selection) { range in
                    range.rawValue
                }
                .padding(.horizontal)

                CompactGlassSegmentedPicker(selection: $selection) { range in
                    range.rawValue
                }
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    return PreviewWrapper()
}
