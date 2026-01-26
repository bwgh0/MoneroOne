import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PINEntryView: View {
    @Binding var pin: String
    let length: Int
    let label: String
    var autoFocus: Bool = false
    var onComplete: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            // Label
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Dot indicators
            HStack(spacing: 12) {
                ForEach(0..<length, id: \.self) { index in
                    let isFilled = index < pin.count
                    let isNextDot = index == pin.count && isFocused
                    Circle()
                        .fill(isFilled ? Color.orange : Color.gray.opacity(0.3))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isNextDot ? Color.orange : (isFilled ? Color.orange : Color.gray.opacity(0.5)),
                                    lineWidth: isNextDot ? 2 : 1
                                )
                        )
                        .scaleEffect(isNextDot ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isNextDot)
                        .animation(.spring(response: 0.2), value: pin.count)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isFocused = true
            }

            // Hidden input field using TextField with secure display
            TextField("", text: $pin)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .focused($isFocused)
                .onChange(of: pin) { newValue in
                    // Filter to digits only
                    let filtered = newValue.filter { $0.isNumber }
                    if filtered != newValue {
                        pin = filtered
                    }
                    // Limit to max length
                    if pin.count > length {
                        pin = String(pin.prefix(length))
                    }
                    // Trigger completion
                    if pin.count == length {
                        onComplete?()
                    }
                }
        }
        .onAppear {
            if autoFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isFocused = true
                }
            }
        }
    }
}

// Version with external focus binding
struct PINEntryFieldView<Field: Hashable>: View {
    @Binding var pin: String
    let length: Int
    let label: String
    var field: Field
    var focusedField: FocusState<Field?>.Binding
    var onComplete: (() -> Void)? = nil

    private var isFieldFocused: Bool {
        focusedField.wrappedValue == field
    }

    var body: some View {
        VStack(spacing: 16) {
            // Label
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Dot indicators
            HStack(spacing: 12) {
                ForEach(0..<length, id: \.self) { index in
                    let isFilled = index < pin.count
                    let isNextDot = index == pin.count && isFieldFocused
                    Circle()
                        .fill(isFilled ? Color.orange : Color.gray.opacity(0.3))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isNextDot ? Color.orange : (isFilled ? Color.orange : Color.gray.opacity(0.5)),
                                    lineWidth: isNextDot ? 2 : 1
                                )
                        )
                        .scaleEffect(isNextDot ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isNextDot)
                        .animation(.spring(response: 0.2), value: pin.count)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                focusedField.wrappedValue = field
            }

            // Hidden input field
            TextField("", text: $pin)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .focused(focusedField, equals: field)
                .onChange(of: pin) { newValue in
                    // Filter to digits only
                    let filtered = newValue.filter { $0.isNumber }
                    if filtered != newValue {
                        pin = filtered
                    }
                    // Limit to max length
                    if pin.count > length {
                        pin = String(pin.prefix(length))
                    }
                    // Trigger completion
                    if pin.count == length {
                        onComplete?()
                    }
                }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var pin = ""

        var body: some View {
            VStack(spacing: 32) {
                PINEntryView(pin: $pin, length: 4, label: "Enter PIN")
                PINEntryView(pin: $pin, length: 6, label: "Enter PIN")
                Text("PIN: \(pin)")
            }
            .padding()
        }
    }

    return PreviewWrapper()
}
