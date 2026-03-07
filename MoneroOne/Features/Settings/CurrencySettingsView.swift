import SwiftUI

struct CurrencySettingsView: View {
    @ObservedObject var priceService: PriceService

    private let currencies: [(code: String, name: String)] = [
        ("usd", "US Dollar"),
        ("eur", "Euro"),
        ("gbp", "British Pound"),
        ("cad", "Canadian Dollar"),
        ("aud", "Australian Dollar"),
        ("jpy", "Japanese Yen"),
        ("cny", "Chinese Yuan")
    ]

    var body: some View {
        List {
            Section {
                ForEach(currencies, id: \.code) { currency in
                    Button {
                        priceService.setCurrency(currency.code)
                    } label: {
                        HStack {
                            Text(flagEmoji(for: currency.code))
                                .font(.title2)

                            VStack(alignment: .leading) {
                                Text(currency.name)
                                    .foregroundColor(.primary)
                                Text(currency.code.uppercased())
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if priceService.selectedCurrency == currency.code {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.orange)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            } header: {
                Text("Display Currency")
            } footer: {
                Text("Fiat values are fetched from CoinMarketCap and update every 5 minutes.")
            }

            Section("Current Price") {
                if priceService.isLoading {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Fetching price...")
                            .foregroundColor(.secondary)
                    }
                } else if let price = priceService.xmrPrice {
                    HStack {
                        Text("1 XMR")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(priceService.currencySymbol)\(String(format: "%.2f", price))")
                            .fontWeight(.semibold)
                    }

                    if let change = priceService.priceChange24h {
                        HStack {
                            Text("24h Change")
                                .foregroundColor(.secondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                Text(priceService.formatPriceChange() ?? "")
                            }
                            .foregroundColor(change >= 0 ? .green : .red)
                            .fontWeight(.medium)
                        }
                    }

                    if let lastUpdated = priceService.lastUpdated {
                        HStack {
                            Text("Last Updated")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(lastUpdated, style: .relative)
                                .foregroundColor(.secondary)
                        }
                    }
                } else if let error = priceService.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await priceService.fetchPrice()
        }
    }

    private func flagEmoji(for code: String) -> String {
        switch code {
        case "usd": return "🇺🇸"
        case "eur": return "🇪🇺"
        case "gbp": return "🇬🇧"
        case "cad": return "🇨🇦"
        case "aud": return "🇦🇺"
        case "jpy": return "🇯🇵"
        case "cny": return "🇨🇳"
        default: return "💵"
        }
    }
}

#Preview {
    NavigationStack {
        CurrencySettingsView(priceService: PriceService())
    }
}
