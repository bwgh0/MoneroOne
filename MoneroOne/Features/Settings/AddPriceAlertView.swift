import SwiftUI

struct AddPriceAlertView: View {
    @ObservedObject var priceAlertService: PriceAlertService
    @ObservedObject var priceService: PriceService
    @Environment(\.dismiss) private var dismiss

    @State private var alertType: PriceAlert.AlertType = .above
    @State private var targetPriceText = ""
    @FocusState private var isTextFieldFocused: Bool

    private var currencySymbol: String {
        priceService.currencySymbol
    }

    private var isValidPrice: Bool {
        guard let price = Double(targetPriceText), price > 0 else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                if let currentPrice = priceService.xmrPrice {
                    Section("Current Price") {
                        HStack {
                            Text("1 XMR")
                            Spacer()
                            Text("\(currencySymbol)\(String(format: "%.2f", currentPrice))")
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section("Alert Type") {
                    Picker("Alert when price goes", selection: $alertType) {
                        Text("Above").tag(PriceAlert.AlertType.above)
                        Text("Below").tag(PriceAlert.AlertType.below)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    HStack {
                        Text(currencySymbol)
                            .foregroundColor(.secondary)
                        TextField("Target price", text: $targetPriceText)
                            .keyboardType(.decimalPad)
                            .focused($isTextFieldFocused)
                        Text(priceService.selectedCurrency.uppercased())
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Target Price")
                } footer: {
                    if alertType == .above {
                        Text("You'll be notified when XMR goes above this price")
                    } else {
                        Text("You'll be notified when XMR drops below this price")
                    }
                }

                Section {
                    Button {
                        saveAlert()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Save Alert")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!isValidPrice)
                    .listRowBackground(isValidPrice ? Color.orange : Color.orange.opacity(0.3))
                    .foregroundColor(.white)
                }
            }
            .navigationTitle("New Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Pre-fill with current price as starting point
                if let price = priceService.xmrPrice {
                    let suggestedPrice = alertType == .above
                        ? price * 1.05  // 5% above
                        : price * 0.95  // 5% below
                    targetPriceText = String(format: "%.2f", suggestedPrice)
                }
                isTextFieldFocused = true
            }
            .onChange(of: alertType) { newType in
                // Update suggested price when type changes
                if let price = priceService.xmrPrice {
                    let suggestedPrice = newType == .above
                        ? price * 1.05
                        : price * 0.95
                    targetPriceText = String(format: "%.2f", suggestedPrice)
                }
            }
        }
    }

    private func saveAlert() {
        guard let targetPrice = Double(targetPriceText), targetPrice > 0 else { return }

        priceAlertService.addAlert(
            type: alertType,
            targetPrice: targetPrice,
            currency: priceService.selectedCurrency
        )

        dismiss()
    }
}

#Preview {
    AddPriceAlertView(
        priceAlertService: PriceAlertService(),
        priceService: PriceService()
    )
}
