import Foundation
import Combine

@MainActor
class PriceService: ObservableObject {
    @Published var xmrPrice: Double?
    @Published var priceChange24h: Double?
    @Published var lastUpdated: Date?
    @Published var selectedCurrency: String = "usd"
    @Published var isLoading = false
    @Published var error: String?

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 60 // 1 minute

    static let supportedCurrencies = ["usd", "eur", "gbp", "cad", "aud", "jpy", "cny"]

    static let currencySymbols: [String: String] = [
        "usd": "$",
        "eur": "€",
        "gbp": "£",
        "cad": "C$",
        "aud": "A$",
        "jpy": "¥",
        "cny": "¥"
    ]

    init() {
        loadCurrency()
        startAutoRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func loadCurrency() {
        if let saved = UserDefaults.standard.string(forKey: "selectedCurrency") {
            selectedCurrency = saved
        }
    }

    func setCurrency(_ currency: String) {
        selectedCurrency = currency
        UserDefaults.standard.set(currency, forKey: "selectedCurrency")
        Task {
            await fetchPrice()
        }
    }

    var currencySymbol: String {
        Self.currencySymbols[selectedCurrency] ?? "$"
    }

    func startAutoRefresh() {
        Task {
            await fetchPrice()
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchPrice()
            }
        }
    }

    func fetchPrice() async {
        isLoading = true
        error = nil

        let urlString = "https://api.coingecko.com/api/v3/simple/price?ids=monero&vs_currencies=\(selectedCurrency)&include_24hr_change=true"

        guard let url = URL(string: urlString) else {
            error = "Invalid URL"
            isLoading = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Server error"
                isLoading = false
                return
            }

            let result = try JSONDecoder().decode(CoinGeckoResponse.self, from: data)

            if let moneroData = result.monero {
                xmrPrice = moneroData[selectedCurrency]
                priceChange24h = moneroData["\(selectedCurrency)_24h_change"]
                lastUpdated = Date()
            }
        } catch {
            self.error = "Failed to fetch price"
            print("Price fetch error: \(error)")
        }

        isLoading = false
    }

    func formatFiatValue(_ xmrAmount: Decimal) -> String? {
        guard let price = xmrPrice else { return nil }

        let fiatValue = (xmrAmount as NSDecimalNumber).doubleValue * price
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = selectedCurrency.uppercased()

        return formatter.string(from: NSNumber(value: fiatValue))
    }

    func formatPriceChange() -> String? {
        guard let change = priceChange24h else { return nil }
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }
}

// MARK: - CoinGecko Response

struct CoinGeckoResponse: Codable {
    let monero: [String: Double]?
}
