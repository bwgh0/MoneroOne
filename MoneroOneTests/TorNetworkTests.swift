import Network
import XCTest
@testable import MoneroOne

/// A SOCKS5 proxy on the loopback interface. It records each CONNECT
/// request (address type, host, port), then answers "connection refused".
private final class RecordingSocksProxy: @unchecked Sendable {
    struct Connect: Equatable {
        let addressType: UInt8
        let host: String
        let port: UInt16
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "one.monero.tests.socks")
    private var connects: [Connect] = []
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var address: String { "127.0.0.1:\(port)" }
    var route: TorNetwork.Route { TorNetwork.route(for: address) }
    var recorded: [Connect] { queue.sync { connects } }

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.read(connection, buffer: Data(), greeted: false)
            }
            listener.start(queue: queue)
        }
    }

    private func read(_ connection: NWConnection, buffer: Data, greeted: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var input = buffer
            if let data { input.append(data) }
            var greeted = greeted
            let bytes = [UInt8](input)
            if !greeted {
                // Greeting: version, method count, methods. Reply: no authentication.
                if bytes.count >= 2, bytes.count >= 2 + Int(bytes[1]) {
                    greeted = true
                    input.removeAll()
                    connection.send(content: Data([0x05, 0x00]), completion: .idempotent)
                }
            } else if let connect = Self.parseRequest(bytes) {
                self.connects.append(connect)
                // Reply 5: connection refused. Then close.
                connection.send(content: Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer: input, greeted: greeted)
            }
        }
    }

    /// Version, command, reserved, address type, address, port. Nil until complete.
    private static func parseRequest(_ bytes: [UInt8]) -> Connect? {
        guard bytes.count >= 5 else { return nil }
        let start: Int
        let end: Int
        var host = ""
        switch bytes[3] {
        case 0x01:
            start = 4
            end = 8
        case 0x03:
            start = 5
            end = 5 + Int(bytes[4])
        case 0x04:
            start = 4
            end = 20
        default:
            return nil
        }
        guard bytes.count >= end + 2 else { return nil }
        if bytes[3] == 0x03 {
            host = String(decoding: bytes[start..<end], as: UTF8.self)
        }
        let port = UInt16(bytes[end]) << 8 | UInt16(bytes[end + 1])
        return Connect(addressType: bytes[3], host: host, port: port)
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
    }

    /// Waits up to `timeout` for a CONNECT that `match` accepts.
    func waitFor(timeout: TimeInterval = 10, _ match: (Connect) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if recorded.contains(where: match) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return recorded.contains(where: match)
    }
}

/// A route that a test can change.
private final class RouteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TorNetwork.Route
    init(_ value: TorNetwork.Route) { self.value = value }
    var route: TorNetwork.Route {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
final class TorNetworkTests: XCTestCase {
    private var proxies: [RecordingSocksProxy] = []

    override func tearDown() async throws {
        proxies.forEach { $0.stop() }
        proxies = []
    }

    private func startProxy() async throws -> RecordingSocksProxy {
        let proxy = try RecordingSocksProxy()
        proxies.append(proxy)
        await proxy.start()
        XCTAssertNotEqual(proxy.port, 0)
        return proxy
    }

    /// Sets the saved Tor setting for one test, and puts the old one back after.
    private func setTorSetting(_ value: String?) {
        let key = TorNetwork.proxyKey
        let saved = UserDefaults.standard.object(forKey: key)
        addTeardownBlock {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: Route

    func testRouteFromSetting() throws {
        XCTAssertEqual(TorNetwork.route(for: nil), .direct)
        XCTAssertEqual(TorNetwork.route(for: ""), .direct)
        XCTAssertEqual(TorNetwork.route(for: "   "), .direct)
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: 9050))
        XCTAssertEqual(TorNetwork.route(for: "127.0.0.1:9050"), .tor(TorNetwork.Proxy(host: "127.0.0.1", port: port)))
        XCTAssertEqual(TorNetwork.route(for: " [::1]:9050 "), .tor(TorNetwork.Proxy(host: "::1", port: port)))
        for bad in ["not-a-proxy", "localhost:", ":9050", "localhost:0", "localhost:70000", "localhost:90x0"] {
            XCTAssertEqual(TorNetwork.route(for: bad), .blocked, bad)
        }
        XCTAssertFalse(TorNetwork.Route.direct.isTor)
        XCTAssertTrue(TorNetwork.Route.blocked.isTor)
    }

    func testCurrentRouteReadsTheSavedSetting() {
        setTorSetting(nil)
        XCTAssertEqual(TorNetwork.currentRoute(), .direct)
        setTorSetting("127.0.0.1:9050")
        XCTAssertTrue(TorNetwork.currentRoute().isTor)
        setTorSetting("bad")
        XCTAssertEqual(TorNetwork.currentRoute(), .blocked)
    }

    func testProxyConfigurationNeverFailsOver() throws {
        let proxy = try XCTUnwrap(TorNetwork.parseProxy("127.0.0.1:9050"))
        XCTAssertFalse(TorNetwork.proxyConfiguration(for: proxy).allowFailover)

        let configuration = URLSessionConfiguration.ephemeral
        try TorNetwork.apply(.tor(proxy), to: configuration)
        XCTAssertEqual(configuration.proxyConfigurations.count, 1)
        XCTAssertEqual(configuration.proxyConfigurations.first?.allowFailover, false)
        try TorNetwork.apply(.direct, to: configuration)
        XCTAssertTrue(configuration.proxyConfigurations.isEmpty)
    }

    func testBlockedRouteConfiguresNothing() {
        XCTAssertThrowsError(try TorNetwork.apply(.blocked, to: URLSessionConfiguration.ephemeral)) {
            XCTAssertEqual($0 as? TorNetwork.RouteError, .proxyInvalid)
        }
        XCTAssertThrowsError(try TorNetwork.apply(.blocked, to: NWParameters.tcp, description: "test")) {
            XCTAssertEqual($0 as? TorNetwork.RouteError, .proxyInvalid)
        }
    }

    /// An IPv4 address as text, built from its parts at run time.
    private static func ipv4(_ parts: Int...) -> String {
        parts.map(String.init).joined(separator: ".")
    }

    func testTorBlocksLocalAddressTargetsOnly() throws {
        let tor = TorNetwork.route(for: "127.0.0.1:9050")
        let locals = [Self.ipv4(192, 168, 1, 5), Self.ipv4(10, 0, 0, 2), Self.ipv4(127, 0, 0, 1),
                      Self.ipv4(172, 16, 0, 1), "fe80::1", "::1"]
        for local in locals {
            XCTAssertTrue(TorNetwork.blocksTarget(host: local, on: tor), local)
            XCTAssertTrue(TorNetwork.blocksTarget(host: local, on: .blocked), local)
            XCTAssertFalse(TorNetwork.blocksTarget(host: local, on: .direct), local)
        }
        for name in ["node.monero.one", "monero.one", "abc.onion", "localhost", Self.ipv4(8, 8, 8, 8)] {
            XCTAssertFalse(TorNetwork.blocksTarget(host: name, on: tor), name)
        }
    }

    // MARK: Session

    func testBlockedRouteSendsNothing() async throws {
        let session = TorURLSession(route: { .blocked })
        let url = try XCTUnwrap(URL(string: "https://monero.one/api/v1/price"))
        do {
            _ = try await session.data(from: url)
            XCTFail("A blocked route must not connect")
        } catch {
            XCTAssertEqual(error as? TorNetwork.RouteError, .proxyInvalid)
        }

        let failed = expectation(description: "completion")
        let task = session.dataTask(with: URLRequest(url: url)) { data, response, error in
            XCTAssertNil(data)
            XCTAssertNil(response)
            XCTAssertEqual(error as? TorNetwork.RouteError, .proxyInvalid)
            failed.fulfill()
        }
        XCTAssertNil(task)
        await fulfillment(of: [failed], timeout: 1)
    }

    func testLocalTargetWithTorSendsNothing() async throws {
        let proxy = try await startProxy()
        let session = TorURLSession(route: { [route = proxy.route] in route })
        let url = try XCTUnwrap(URL(string: "http://\(Self.ipv4(192, 168, 1, 5)):18081/get_info"))
        do {
            _ = try await session.data(from: url)
            XCTFail("A local target must not connect with Tor on")
        } catch {
            XCTAssertEqual(error as? TorNetwork.RouteError, .localTarget)
        }
        XCTAssertTrue(proxy.recorded.isEmpty)
    }

    func testTorRequestSendsTheHostNameToTheProxy() async throws {
        let proxy = try await startProxy()
        let session = TorURLSession(route: { [route = proxy.route] in route })
        let url = try XCTUnwrap(URL(string: "https://monero.one/api/v1/price"))
        do {
            _ = try await session.data(from: url)
            XCTFail("The proxy refuses every connection")
        } catch {
            // Expected: the proxy refused, and there is no direct fallback.
        }
        // Address type 3: the proxy, not the device, resolves the name.
        XCTAssertEqual(proxy.recorded, [.init(addressType: 3, host: "monero.one", port: 443)])
    }

    func testProxyDownFailsWithoutFallback() async throws {
        // A port with no listener: the proxy is down.
        let proxy = try await startProxy()
        let route = proxy.route
        proxy.stop()
        let session = TorURLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            return configuration
        }, route: { route })
        let url = try XCTUnwrap(URL(string: "https://monero.one/api/v1/price"))
        do {
            _ = try await session.data(from: url)
            XCTFail("With the proxy down, the request must fail, never go direct")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }
    }

    func testRouteChangeReplacesTheSession() throws {
        let box = RouteBox(.direct)
        let session = TorURLSession(route: { box.route })
        let direct = try session.session(for: box.route)
        XCTAssertTrue(direct === (try session.session(for: box.route)), "One session per route")
        XCTAssertTrue(direct.configuration.proxyConfigurations.isEmpty)

        box.route = TorNetwork.route(for: "127.0.0.1:9050")
        let tor = try session.session(for: box.route)
        XCTAssertFalse(direct === tor)
        XCTAssertEqual(tor.configuration.proxyConfigurations.count, 1)
    }

    /// A Tor switch cancels a direct request in flight, and the late
    /// answer never counts.
    func testTorSwitchCancelsADirectRequestInFlight() async throws {
        // A server that accepts and never answers.
        let silent = try NWListener(using: {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            return parameters
        }())
        var held: [NWConnection] = []
        let queue = DispatchQueue(label: "one.monero.tests.silent")
        silent.newConnectionHandler = { connection in
            held.append(connection)
            connection.start(queue: queue)
        }
        let ready = expectation(description: "listening")
        silent.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        silent.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        defer {
            silent.cancel()
            queue.sync { held.forEach { $0.cancel() } }
        }
        let port = try XCTUnwrap(silent.port?.rawValue)

        let box = RouteBox(.direct)
        let session = TorURLSession(route: { box.route })
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/get_info"))
        let request = Task { try await session.data(from: url) }
        try await Task.sleep(nanoseconds: 300_000_000)

        box.route = TorNetwork.route(for: "127.0.0.1:9050")
        // Any UserDefaults change makes each session check its route.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)

        let started = Date()
        do {
            _ = try await request.value
            XCTFail("The direct request must end when Tor turns on")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    // MARK: Services

    func testChartFetchGoesThroughTheProxy() async throws {
        let proxy = try await startProxy()
        setTorSetting(proxy.address)
        let prices = PriceService()
        await prices.fetchChartData(range: "1D", force: true)
        XCTAssertEqual(proxy.recorded.first, .init(addressType: 3, host: "monero.one", port: 443))
        XCTAssertTrue(proxy.recorded.allSatisfy { $0.addressType == 3 })
    }

    func testPriceFetchGoesThroughTheProxyAndFails() async throws {
        let proxy = try await startProxy()
        setTorSetting(proxy.address)
        let prices = PriceService()
        await prices.fetchPrice()
        XCTAssertNotNil(prices.error, "With the proxy refusing, the price fails as it does offline")
        XCTAssertFalse(proxy.recorded.isEmpty)
        XCTAssertTrue(proxy.recorded.allSatisfy { $0 == .init(addressType: 3, host: "monero.one", port: 443) })
    }

    func testBadTorSettingStopsThePriceFetch() async throws {
        setTorSetting("not-a-proxy")
        let prices = PriceService()
        await prices.fetchChartData(range: "1D", force: true)
        XCTAssertNil(prices.chartDataCache["1D"], "No request, so no chart")
    }

    func testPriceHistoryGoesThroughTheProxy() async throws {
        let proxy = try await startProxy()
        let route = proxy.route
        let history = PriceHistoryService(priceService: PriceService(), cacheDirectory: nil,
                                          session: TorURLSession(route: { route }))
        history.startAutoRefresh()
        let asked = await proxy.waitFor { $0.host == "monero.one" && $0.port == 443 }
        XCTAssertTrue(asked)
        XCTAssertTrue(proxy.recorded.allSatisfy { $0.addressType == 3 })
    }

    func testUptimeFetchAndLatencyProbesGoThroughTheProxy() async throws {
        // Node settings come back after the test; auto-select stays off, so
        // the test switches no node.
        let keys = ["isTestnet", "selectedNodeURL", "customNodes", "autoSelectNode"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, saved) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        ["isTestnet", "selectedNodeURL", "customNodes"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(false, forKey: "autoSelectNode")

        let proxy = try await startProxy()
        setTorSetting(proxy.address)
        let manager = NodeManager()
        XCTAssertFalse(manager.autoSelectEnabled)

        await manager.fetchUptimeStats()
        await manager.measureAllLatencies()

        let recorded = proxy.recorded
        XCTAssertTrue(recorded.allSatisfy { $0.addressType == 3 }, "The proxy resolves every name")
        XCTAssertTrue(recorded.contains { $0.host == "raw.githubusercontent.com" && $0.port == 443 })
        for node in manager.allNodes where !node.url.contains(".onion") {
            let url = try XCTUnwrap(URL(string: node.url))
            let host = try XCTUnwrap(url.host)
            if NodeLoginProbe.isNonPublicAddress(host) { continue }
            XCTAssertTrue(recorded.contains { $0.host == host }, "Probe of \(node.name) went through the proxy")
        }
        // Onion nodes are not probed, as before.
        XCTAssertFalse(recorded.contains { $0.host.hasSuffix(".onion") })
    }
}
