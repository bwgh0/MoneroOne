import Foundation

/// HTTP client for Monero Light Wallet Server (LWS)
/// Used in Lite Mode to sync wallet via server-side view key scanning
actor LiteWalletServerClient {
    // MARK: - Server Configuration

    /// Get the server URL from centralized configuration
    static func serverURL(isTestnet: Bool) -> String {
        ServerConfiguration.lwsServerURL(isTestnet: isTestnet)
    }

    private let session: URLSession
    private let baseURL: String

    init(isTestnet: Bool = true) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.baseURL = Self.serverURL(isTestnet: isTestnet)
    }

    // MARK: - API Endpoints

    /// Register a wallet with the LWS for tracking
    func register(address: String, viewKey: String, startHeight: UInt64? = nil) async throws -> LWSRegisterResponse {
        let body = LWSRegisterRequest(address: address, viewKey: viewKey, startHeight: startHeight)
        return try await post("/api/account/register", body: body)
    }

    /// Get sync status for an account
    func syncStatus(address: String) async throws -> LWSSyncStatusResponse {
        let body = LWSSyncStatusRequest(address: address)
        return try await post("/api/account/sync_status", body: body)
    }

    /// Get wallet balance
    func getBalance(address: String, viewKey: String) async throws -> LWSBalanceResponse {
        let body = LWSBalanceRequest(address: address, viewKey: viewKey)
        return try await post("/api/account/balance", body: body)
    }

    /// Get wallet transactions
    func getTransactions(address: String, viewKey: String, fromHeight: UInt64? = nil) async throws -> LWSTransactionsResponse {
        let body = LWSTransactionsRequest(address: address, viewKey: viewKey, fromHeight: fromHeight)
        return try await post("/api/account/transactions", body: body)
    }

    /// Submit a signed transaction to the network
    func sendTransaction(signedTxHex: String) async throws -> LWSSendResponse {
        let body = LWSSendRequest(signedTxHex: signedTxHex)
        return try await post("/api/account/send", body: body)
    }

    /// Get current blockchain height
    func getBlockchainHeight() async throws -> LWSHeightResponse {
        return try await get("/api/blockchain/height")
    }

    /// Check server health
    func healthCheck() async throws -> LWSHealthResponse {
        return try await get("/api/blockchain/health")
    }

    // MARK: - HTTP Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw LWSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        return try handleResponse(data: data, response: response)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw LWSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        return try handleResponse(data: data, response: response)
    }

    private func handleResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LWSError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        case 400:
            throw LWSError.badRequest(parseError(data))
        case 401:
            throw LWSError.unauthorized
        case 404:
            throw LWSError.notFound
        case 429:
            throw LWSError.rateLimited
        case 500...599:
            throw LWSError.serverError(parseError(data))
        default:
            throw LWSError.unexpectedStatus(httpResponse.statusCode)
        }
    }

    private func parseError(_ data: Data) -> String {
        if let errorResponse = try? JSONDecoder().decode(LWSErrorResponse.self, from: data) {
            return errorResponse.error
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}

// MARK: - Error Types

enum LWSError: LocalizedError {
    case invalidURL
    case invalidResponse
    case badRequest(String)
    case unauthorized
    case notFound
    case rateLimited
    case serverError(String)
    case unexpectedStatus(Int)
    case notRegistered

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .invalidResponse: return "Invalid server response"
        case .badRequest(let msg): return "Bad request: \(msg)"
        case .unauthorized: return "Unauthorized - check view key"
        case .notFound: return "Account not found on server"
        case .rateLimited: return "Rate limited - please wait"
        case .serverError(let msg): return "Server error: \(msg)"
        case .unexpectedStatus(let code): return "Unexpected status: \(code)"
        case .notRegistered: return "Wallet not registered with light server"
        }
    }
}

// MARK: - Request Models

struct LWSRegisterRequest: Encodable {
    let address: String
    let viewKey: String
    let startHeight: UInt64?
}

struct LWSSyncStatusRequest: Encodable {
    let address: String
}

struct LWSBalanceRequest: Encodable {
    let address: String
    let viewKey: String
}

struct LWSTransactionsRequest: Encodable {
    let address: String
    let viewKey: String
    let fromHeight: UInt64?
}

struct LWSSendRequest: Encodable {
    let signedTxHex: String
}

// MARK: - Response Models

struct LWSErrorResponse: Decodable {
    let error: String
}

struct LWSRegisterResponse: Decodable {
    let accountId: String
    let isNew: Bool
    let message: String?
}

struct LWSBalanceResponse: Decodable {
    let totalBalance: String
    let unlockedBalance: String
    let height: UInt64
}

struct LWSTransactionsResponse: Decodable {
    let transactions: [LWSTransaction]
    let height: UInt64
}

struct LWSTransaction: Decodable {
    let txHash: String
    let amount: String
    let fee: String?
    let isIncoming: Bool
    let blockHeight: UInt64?
    let timestamp: UInt64?
    let address: String?
    let confirmations: Int?
}

struct LWSSendResponse: Decodable {
    let txHash: String
    let status: String
}

struct LWSHeightResponse: Decodable {
    let height: UInt64
    let timestamp: UInt64?
}

struct LWSHealthResponse: Decodable {
    let status: String
    let daemonHeight: UInt64
    let daemonSynced: Bool
    let daemon: String?
    let scanner: String?
}

struct LWSSyncStatusResponse: Decodable {
    let scannedHeight: UInt64
    let chainHeight: UInt64
    let percentComplete: Int
}

// MARK: - Server Configuration

/// Centralized server configuration
/// URLs are read from Info.plist which can be configured via xcconfig or build settings
/// This keeps sensitive URLs out of source code for open source releases
enum ServerConfiguration {

    /// LWS server URL for testnet
    static var testnetLWSServerURL: String {
        // Read from Info.plist, fall back to environment variable, then default
        if let url = Bundle.main.object(forInfoDictionaryKey: "LWS_TESTNET_URL") as? String,
           !url.isEmpty, !url.hasPrefix("$") {
            return url
        }
        if let url = ProcessInfo.processInfo.environment["LWS_TESTNET_URL"],
           !url.isEmpty {
            return url
        }
        // Default for development - this should be overridden in production builds
        #if DEBUG
        return "http://localhost:3000"
        #else
        fatalError("LWS_TESTNET_URL not configured. Set in Info.plist or environment.")
        #endif
    }

    /// LWS server URL for mainnet
    static var mainnetLWSServerURL: String {
        if let url = Bundle.main.object(forInfoDictionaryKey: "LWS_MAINNET_URL") as? String,
           !url.isEmpty, !url.hasPrefix("$") {
            return url
        }
        if let url = ProcessInfo.processInfo.environment["LWS_MAINNET_URL"],
           !url.isEmpty {
            return url
        }
        #if DEBUG
        return "http://localhost:3000"
        #else
        fatalError("LWS_MAINNET_URL not configured. Set in Info.plist or environment.")
        #endif
    }

    /// Get the appropriate LWS URL based on network
    static func lwsServerURL(isTestnet: Bool) -> String {
        isTestnet ? testnetLWSServerURL : mainnetLWSServerURL
    }
}
