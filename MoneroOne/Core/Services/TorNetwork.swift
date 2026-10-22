import Foundation
import Network

// MARK: - Route

/// The one route for every connection the app makes. The Tor setting is a
/// SOCKS proxy `host:port` saved under `proxyAddress`, empty when Tor is off.
///
/// With Tor on, each connection goes through that proxy as SOCKS5 and the
/// proxy resolves the host names, so the device never looks one up. There
/// is no direct fallback: when the proxy is down, the connection fails, and
/// when the setting fails to parse, nothing connects. With Tor off,
/// connections go direct, as before.
///
/// wallet2 reads the same setting through `MoneroKit.Node.proxy` and
/// connects with SOCKS4a, which also sends the host name to the proxy.
enum TorNetwork {
    /// The UserDefaults key of the Tor setting.
    static let proxyKey = "proxyAddress"

    struct Proxy: Equatable, Sendable {
        let host: String
        let port: NWEndpoint.Port
    }

    enum Route: Equatable, Sendable {
        case direct
        case tor(Proxy)
        /// Tor is on, but the proxy setting fails to parse: no connection.
        case blocked

        var isTor: Bool { self != .direct }
    }

    enum RouteError: Error, Equatable {
        /// Tor is on and the proxy setting fails to parse.
        case proxyInvalid
        /// Tor is on and the target is a local address, which
        /// Network.framework reaches past the proxy.
        case localTarget
        /// The Tor setting changed while the request ran.
        case routeChanged
    }

    /// The route for a saved Tor setting.
    static func route(for proxyText: String?) -> Route {
        let text = (proxyText ?? "").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .direct }
        guard let proxy = parseProxy(text) else { return .blocked }
        return .tor(proxy)
    }

    /// The route for the saved Tor setting. UserDefaults loads at once, so a
    /// request never starts before the setting is known.
    static func currentRoute(_ defaults: UserDefaults = .standard) -> Route {
        route(for: defaults.string(forKey: proxyKey))
    }

    /// `host:port`, split at the last `:`. A bracketed IPv6 host loses its
    /// brackets. Nil when it fails to parse.
    static func parseProxy(_ raw: String) -> Proxy? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let colon = text.lastIndex(of: ":") else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let portText = text[text.index(after: colon)...]
        guard !host.isEmpty,
              portText.allSatisfy(\.isASCII), portText.allSatisfy(\.isNumber),
              let value = UInt16(portText), value > 0,
              let port = NWEndpoint.Port(rawValue: value) else { return nil }
        return Proxy(host: host, port: port)
    }

    /// SOCKS5 through `proxy`, with no failover to a direct connection.
    static func proxyConfiguration(for proxy: Proxy) -> ProxyConfiguration {
        var configuration = ProxyConfiguration(
            socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host), port: proxy.port)
        )
        configuration.allowFailover = false
        return configuration
    }

    /// Puts the route on a session configuration. Throws for a blocked route.
    static func apply(_ route: Route, to configuration: URLSessionConfiguration) throws {
        switch route {
        case .direct:
            configuration.proxyConfigurations = []
        case .tor(let proxy):
            configuration.proxyConfigurations = [proxyConfiguration(for: proxy)]
        case .blocked:
            throw RouteError.proxyInvalid
        }
    }

    /// Puts the route on connection parameters. Throws for a blocked route.
    static func apply(_ route: Route, to parameters: NWParameters, description: String) throws {
        switch route {
        case .direct:
            return
        case .tor(let proxy):
            let context = NWParameters.PrivacyContext(description: description)
            context.proxyConfigurations = [proxyConfiguration(for: proxy)]
            parameters.setPrivacyContext(context)
        case .blocked:
            throw RouteError.proxyInvalid
        }
    }

    /// True when a connection to `host` must not start on `route`.
    /// Network.framework connects to some local addresses directly, past
    /// the proxy, even with failover off. So with Tor on, no connection goes
    /// to a non-public IP address. A host name always goes to the proxy.
    static func blocksTarget(host: String, on route: Route) -> Bool {
        route.isTor && NodeLoginProbe.isNonPublicAddress(host)
    }

    /// Calls `handler` once the route that `current` gives differs from
    /// `route`. It checks after each UserDefaults change. Pass the token to
    /// `NotificationCenter.default.removeObserver(_:)` when done.
    static func onRouteChange(from route: Route,
                              current: @escaping @Sendable () -> Route = { TorNetwork.currentRoute() },
                              _ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        let fired = FiredOnce()
        return NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                      object: nil, queue: nil) { _ in
            if current() != route, fired.fire() { handler() }
        }
    }

    private final class FiredOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        /// True on the first call only.
        func fire() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }
}

// MARK: - Session

/// A URLSession that follows the Tor setting. Each request reads the route
/// first. A route change invalidates the session of the old route and
/// cancels its requests, so no direct session outlives a switch to Tor, and
/// a response that arrives after a route change is dropped.
final class TorURLSession: @unchecked Sendable {
    /// For plain requests: the default configuration, as `URLSession.shared` has.
    static let shared = TorURLSession()

    private let lock = NSLock()
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let delegate: URLSessionDelegate?
    private let routeProvider: @Sendable () -> TorNetwork.Route
    private var session: URLSession?
    private var sessionRoute: TorNetwork.Route?
    private var observer: NSObjectProtocol?

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .default },
         delegate: URLSessionDelegate? = nil,
         route: @escaping @Sendable () -> TorNetwork.Route = { TorNetwork.currentRoute() }) {
        makeConfiguration = configuration
        self.delegate = delegate
        routeProvider = route
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: nil, queue: nil) { [weak self] _ in
            self?.dropSessionIfRouteChanged()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        session?.invalidateAndCancel()
    }

    /// The route a new request takes now.
    var route: TorNetwork.Route { routeProvider() }

    /// The session for `route`. A session made for another route is
    /// invalidated first. Throws for a blocked route, and makes no session.
    func session(for route: TorNetwork.Route) throws -> URLSession {
        try lock.withLock {
            if let session, sessionRoute == route { return session }
            session?.invalidateAndCancel()
            session = nil
            sessionRoute = nil
            let configuration = makeConfiguration()
            try TorNetwork.apply(route, to: configuration)
            let made = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            session = made
            sessionRoute = route
            return made
        }
    }

    /// Ends the session of an old route, and every request in it.
    func dropSessionIfRouteChanged() {
        let current = routeProvider()
        lock.withLock {
            guard let old = session, sessionRoute != current else { return }
            old.invalidateAndCancel()
            session = nil
            sessionRoute = nil
        }
    }

    /// Checks the target, then gives the session for the current route.
    private func prepare(_ request: URLRequest) throws -> (URLSession, TorNetwork.Route) {
        let route = routeProvider()
        if let host = request.url?.host, TorNetwork.blocksTarget(host: host, on: route) {
            throw TorNetwork.RouteError.localTarget
        }
        return (try session(for: route), route)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (session, route) = try prepare(request)
        let result = try await session.data(for: request)
        guard routeProvider() == route else { throw TorNetwork.RouteError.routeChanged }
        return result
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url))
    }

    /// The completion form. When the route allows no connection, it returns
    /// nil and calls `completion` with the error at once.
    @discardableResult
    func dataTask(with request: URLRequest,
                  completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask? {
        let session: URLSession
        let route: TorNetwork.Route
        do {
            (session, route) = try prepare(request)
        } catch {
            completion(nil, nil, error)
            return nil
        }
        let task = session.dataTask(with: request) { [routeProvider] data, response, error in
            if error == nil, routeProvider() != route {
                completion(nil, nil, TorNetwork.RouteError.routeChanged)
            } else {
                completion(data, response, error)
            }
        }
        task.resume()
        return task
    }
}
