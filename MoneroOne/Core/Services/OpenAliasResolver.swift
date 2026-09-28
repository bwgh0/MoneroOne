import Foundation
import MoneroKit
import Network

// OpenAlias lookups (OpenAlias send spec, section 3). The kit validates
// DNSSEC with libunbound. All of its DNS traffic goes over TCP to a bridge on
// the IPv4 loopback, which sends each query as DNS-over-HTTPS on port 443,
// through the Tor proxy when Tor is on.

// MARK: - DoH transport

/// One HTTP reply from a DoH server. The bridge judges it.
struct DohHTTPReply: Equatable {
    let status: Int
    let contentType: String?
    let body: Data
}

/// Sends one DNS message to a DoH server (RFC 8484, POST).
protocol DohTransport: AnyObject, Sendable {
    func post(_ message: Data, to server: URL) async throws -> DohHTTPReply
    /// Ends the session and every request in flight.
    func invalidate()
}

final class URLSessionDohTransport: DohTransport, @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    init(configuration: URLSessionConfiguration) {
        timeout = configuration.timeoutIntervalForRequest
        session = URLSession(configuration: configuration)
    }

    func post(_ message: Data, to server: URL) async throws -> DohHTTPReply {
        var request = URLRequest(url: server, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.setValue("doh-client", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return DohHTTPReply(status: http.statusCode,
                            contentType: http.value(forHTTPHeaderField: "Content-Type"),
                            body: data)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }
}

// MARK: - Bridge

/// A DNS-over-TCP server on the IPv4 loopback for one lookup. Each query of
/// the kit goes to a DoH server, and the answer goes back on the same
/// connection. A new bridge serves each lookup; `stop()` ends it.
final class DnsBridge: @unchecked Sendable {
    /// The listener was not ready before the deadline of `start(timeout:)`.
    struct StartTimeout: Error {}

    private let transport: DohTransport
    private let servers: [URL]
    private let queryCap: Int
    private let listenerQueue: DispatchQueue
    private let lock = NSLock()

    // Guarded by `lock`.
    private var listener: NWListener?
    /// The caller of `start()`, until the listener is ready.
    private var starting: ResumeOnce<UInt16>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var queries = 0
    private var answered = 0
    private var synthesized = 0
    private var preferred = 0
    private var isDown = false
    private var stopped = false

    init(transport: DohTransport, servers: [URL], queryCap: Int = OpenAliasResolver.Config.queryCap,
         listenerQueue: DispatchQueue = DispatchQueue(label: "one.monero.openalias.bridge")) {
        self.transport = transport
        self.servers = servers
        self.queryCap = queryCap
        self.listenerQueue = listenerQueue
    }

    /// Queries that a DoH server answered.
    var answeredCount: Int { lock.withLock { answered } }
    /// Queries that got a SERVFAIL made by the bridge.
    var synthesizedCount: Int { lock.withLock { synthesized } }

    /// Listens on the IPv4 loopback, on a port that the system picks.
    /// Returns that port once the listener is ready. It throws, and the
    /// bridge stops, when the listener fails or waits for a network, when
    /// it is not ready after `timeout` seconds, or when the task is cancelled.
    func start(timeout: TimeInterval = TimeInterval(OpenAliasResolver.Config.kitTimeoutDirectMs) / 1000) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        // Bound to the loopback address, so only this device can connect.
        // `acceptLocalOnly` stays off: on iOS 27 it resets every loopback
        // connection before the handler sees it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let once = ResumeOnce(continuation)
                let registered: Bool = lock.withLock {
                    guard !stopped else { return false }
                    self.listener = listener
                    starting = once
                    return true
                }
                guard registered else {
                    once.resume(with: .failure(CancellationError()))
                    return
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let result = Self.startResult(for: state, port: listener?.port?.rawValue) else { return }
                    once.resume(with: result)
                    if case .failure = result { self?.stop() }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
                listener.start(queue: listenerQueue)
                // A stop() after the registration cancelled the listener
                // before it started. Cancel it again, so it never listens.
                if lock.withLock({ stopped }) { listener.cancel() }
                // A loopback listener is ready at once. The deadline ends a
                // start that never gets a state.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    if once.resume(with: .failure(StartTimeout())) { self?.stop() }
                }
            }
        } onCancel: {
            stop()
        }
    }

    /// The result of `start()` for a listener state. Nil while the listener
    /// gets ready.
    static func startResult(for state: NWListener.State, port: UInt16?) -> Result<UInt16, Error>? {
        switch state {
        case .ready:
            if let port, port != 0 { return .success(port) }
            return .failure(NWError.posix(.EADDRNOTAVAIL))
        case .waiting(let error), .failed(let error):
            // The loopback needs no network, so a listener that waits for
            // one never gets ready.
            return .failure(error)
        case .cancelled:
            return .failure(CancellationError())
        default:
            return nil
        }
    }

    /// Closes the listener, every connection and every request in flight.
    /// A `start()` in progress throws `CancellationError`.
    func stop() {
        let (listener, starting, connections, requests): (NWListener?, ResumeOnce<UInt16>?, [NWConnection], [Task<Void, Never>]) = lock.withLock {
            stopped = true
            defer {
                self.listener = nil
                self.starting = nil
                self.connections.removeAll()
                self.requests.removeAll()
            }
            return (self.listener, self.starting, Array(self.connections.values), Array(self.requests.values))
        }
        starting?.resume(with: .failure(CancellationError()))
        listener?.cancel()
        connections.forEach { $0.cancel() }
        requests.forEach { $0.cancel() }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let accepted: Bool = lock.withLock {
            guard !stopped else { return false }
            connections[id] = connection
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        // Each connection has its own serial queue: its reads, and its
        // writes in sequence.
        let queue = DispatchQueue(label: "one.monero.openalias.bridge.connection")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                connection?.cancel()
                self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        readFrame(on: connection, queue: queue)
    }

    /// Reads one frame: a 2-byte big-endian length N, then N bytes.
    private func readFrame(on connection: NWConnection, queue: DispatchQueue) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] header, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let header, header.count == 2 else {
                // A clean end of input only stops the reads; replies in
                // flight may still go out until `stop()`.
                if error != nil || !isComplete { connection.cancel() }
                return
            }
            let bytes = [UInt8](header)
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            guard length >= 12 else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self else { return }
                guard error == nil, let body, body.count == length else {
                    connection.cancel()
                    return
                }
                self.handle(query: [UInt8](body), on: connection, queue: queue)
                self.readFrame(on: connection, queue: queue)
            }
        }
    }

    private enum Route {
        case drop
        case servfail
        case forward(UUID)
    }

    /// Queries of one connection run at the same time and answer in any order.
    private func handle(query: [UInt8], on connection: NWConnection, queue: DispatchQueue) {
        let wellFormed = Self.isWellFormedQuery(query)
        let route: Route = lock.withLock {
            guard !stopped else { return .drop }
            queries += 1
            // A frame that is not one well-formed query never goes upstream.
            // A DoH server answers it with FORMERR or NOTIMPL, and libunbound
            // then asks without EDNS for the rest of the lookup. The answers
            // lose their signatures, and the lookup fails as bogus. A SERVFAIL
            // fails only this query.
            if queries > queryCap || isDown || !wellFormed {
                synthesized += 1
                return .servfail
            }
            return .forward(UUID())
        }
        switch route {
        case .drop:
            return
        case .servfail:
            send(Self.servfail(for: query), on: connection, queue: queue)
        case .forward(let id):
            let task = Task { [weak self] in
                guard let self else { return }
                let reply = await self.forward(query)
                self.lock.withLock { _ = self.requests.removeValue(forKey: id) }
                guard !Task.isCancelled else { return }
                self.send(reply, on: connection, queue: queue)
            }
            let kept: Bool = lock.withLock {
                guard !stopped else { return false }
                requests[id] = task
                return true
            }
            if !kept { task.cancel() }
        }
    }

    /// Sends the query to the preferred server, then to the next server after
    /// a transport failure or a refusal. When every server fails with a
    /// transport failure, the bridge goes down. When a server refuses, the
    /// SERVFAIL fails only this query.
    private func forward(_ query: [UInt8]) async -> [UInt8] {
        var message = query
        message[0] = 0  // RFC 8484, section 4.1: ID 0 on the wire
        message[1] = 0
        let first = lock.withLock { preferred }
        var refused = false
        for offset in 0..<servers.count {
            if Task.isCancelled { break }
            let index = (first + offset) % servers.count
            guard let reply = try? await transport.post(Data(message), to: servers[index]),
                  var answer = Self.dnsReply(reply) else { continue }
            if Self.isRefusal(answer) {
                refused = true
                continue
            }
            answer[0] = query[0]
            answer[1] = query[1]
            lock.withLock {
                guard !stopped else { return }
                preferred = index
                answered += 1
            }
            return answer
        }
        lock.withLock {
            guard !stopped else { return }
            // Only a transport failure marks the bridge down. A server that
            // refuses one query still answers the others.
            if !refused { isDown = true }
            synthesized += 1
        }
        return Self.servfail(for: query)
    }

    private func send(_ reply: [UInt8], on connection: NWConnection, queue: DispatchQueue) {
        guard reply.count <= 65535 else { return }
        let frame = Data([UInt8(reply.count >> 8), UInt8(reply.count & 0xFF)] + reply)
        queue.async {
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    // MARK: DNS messages

    /// The bytes of a DNS reply: status 200, a DNS message content type, 12
    /// to 65535 bytes, and the QR bit set. Else nil, which counts as a
    /// transport failure.
    static func dnsReply(_ reply: DohHTTPReply) -> [UInt8]? {
        guard reply.status == 200,
              let type = reply.contentType?.lowercased(), type.hasPrefix("application/dns-message"),
              (12...65535).contains(reply.body.count) else { return nil }
        let bytes = [UInt8](reply.body)
        guard bytes[2] & 0x80 != 0 else { return nil }
        return bytes
    }

    /// FORMERR or NOTIMPL, which the bridge never passes on. libunbound reads
    /// either one as "this server has no EDNS" and then asks without the DO
    /// bit, so the answers lose their signatures. Every DoH server has EDNS,
    /// so the bridge tries the next server instead.
    static func isRefusal(_ answer: [UInt8]) -> Bool {
        guard answer.count >= 4 else { return false }
        let rcode = answer[3] & 0x0F
        return rcode == Rcode.formerr || rcode == Rcode.notimpl
    }

    private enum Rcode {
        static let formerr: UInt8 = 1
        static let notimpl: UInt8 = 4
    }

    /// One standard query: QR off, opcode 0, one question, no answer or
    /// authority records, and every byte used by the question and the
    /// additional records (the EDNS OPT record and its options). Any other
    /// flag, and any type and class, pass. libunbound 1.16.1 (the Android
    /// kit) sometimes resends a query with its ID written over its flags,
    /// so its QDCOUNT reads 0.
    static func isWellFormedQuery(_ query: [UInt8]) -> Bool {
        // The header, the root name, the type and the class.
        guard query.count >= 17 else { return false }
        guard query[2] & 0x80 == 0, (query[2] >> 3) & 0x0F == 0 else { return false }
        guard uint16(query, 4) == 1, uint16(query, 6) == 0, uint16(query, 8) == 0 else { return false }
        guard var index = endOfName(in: query, at: 12, pointerAllowed: false) else { return false }
        index += 4
        for _ in 0..<uint16(query, 10) {
            guard let end = endOfName(in: query, at: index, pointerAllowed: true),
                  end + 10 <= query.count else { return false }
            index = end + 10 + uint16(query, end + 8)
        }
        return index == query.count
    }

    private static func uint16(_ message: [UInt8], _ index: Int) -> Int {
        Int(message[index]) << 8 | Int(message[index + 1])
    }

    /// The offset after the name at `start`. Nil when a label is bad, when
    /// the name is longer than 255 bytes, or when it runs past the end.
    private static func endOfName(in message: [UInt8], at start: Int, pointerAllowed: Bool) -> Int? {
        var index = start
        var length = 1  // the zero byte at the end
        while index < message.count {
            let label = Int(message[index])
            if label == 0 { return index + 1 }
            if label & 0xC0 == 0xC0 {
                return pointerAllowed && index + 2 <= message.count ? index + 2 : nil
            }
            guard label < 64 else { return nil }
            length += 1 + label
            guard length <= 255 else { return nil }
            index += 1 + label
        }
        return nil
    }

    /// A SERVFAIL for the query: its ID, QR and RA on, opcode, RD and CD
    /// copied, and its question when the question parses.
    static func servfail(for query: [UInt8]) -> [UInt8] {
        var reply: [UInt8] = [
            query[0], query[1],
            0x80 | (query[2] & 0x79),
            0x80 | (query[3] & 0x10) | 0x02,
        ]
        if let question = question(in: query) {
            reply += [0, 1, 0, 0, 0, 0, 0, 0]
            reply += question
        } else {
            reply += [0, 0, 0, 0, 0, 0, 0, 0]
        }
        return reply
    }

    /// The question at offset 12: labels with length bytes below 64 (no
    /// compression pointers), a zero byte, then type and class.
    private static func question(in query: [UInt8]) -> [UInt8]? {
        var index = 12
        while true {
            guard index < query.count else { return nil }
            let length = Int(query[index])
            if length == 0 {
                index += 1
                break
            }
            guard length < 64 else { return nil }
            index += 1 + length
        }
        guard index + 4 <= query.count else { return nil }
        return Array(query[12..<(index + 4)])
    }
}

/// Resumes a continuation once. Later calls do nothing.
private final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    /// True when this call resumed the continuation.
    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        let pending: CheckedContinuation<Value, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
        return pending != nil
    }
}

// MARK: - Resolver

/// Looks up one OpenAlias name: a new bridge, the kit call off the main
/// actor, then the answer mapping of section 3.7.
struct OpenAliasResolver {
    /// Every OpenAlias constant of the app (spec section 3.6).
    enum Config {
        static let kitTimeoutDirectMs: Int32 = 12_000
        static let kitTimeoutTorMs: Int32 = 30_000
        static let dohTimeoutDirect: TimeInterval = 5
        static let dohTimeoutTor: TimeInterval = 15
        static let queryCap = 64
        static let typingDelay: Duration = .milliseconds(800)
        static let pinCap = 500
        static let nameDisplayCap = 40
        static let fade: Double = 0.2
        /// Quad9 first, Mullvad after a transport failure.
        static let servers: [URL] = [
            URL(string: "https://dns.quad9.net/dns-query")!,
            URL(string: "https://dns.mullvad.net/dns-query")!,
        ]
    }

    struct Proxy: Equatable {
        let host: String
        let port: NWEndpoint.Port
    }

    /// The Tor setting: a SOCKS proxy `host:port`, empty when Tor is off.
    var proxyAddress: () -> String? = { UserDefaults.standard.string(forKey: "proxyAddress") }
    var makeTransport: (URLSessionConfiguration) -> DohTransport = { URLSessionDohTransport(configuration: $0) }
    var kitLookup: @Sendable (_ name: String, _ port: UInt16, _ timeoutMs: Int32) -> String = { name, port, timeoutMs in
        Kit.lookupOpenAliasTXT(name: name, forwarderPort: port, timeoutMs: timeoutMs)
    }
    var servers: [URL] = Config.servers

    func resolve(_ name: OpenAliasName,
                 check: @escaping @MainActor @Sendable (String) -> AddressCheck) async -> Result<OpenAliasResult, OpenAliasFailure> {
        let proxyText = (proxyAddress() ?? "").trimmingCharacters(in: .whitespaces)
        let torOn = !proxyText.isEmpty
        let netError: OpenAliasFailure = torOn ? .tor : .network
        var proxy: Proxy?
        if torOn {
            // Never a direct connection with Tor on: a proxy that fails to
            // parse gives the Tor error, and nothing is sent.
            guard let parsed = Self.parseProxy(proxyText) else { return .failure(.tor) }
            proxy = parsed
        }

        let started = Date()
        let timeout = torOn ? Config.dohTimeoutTor : Config.dohTimeoutDirect
        let transport = makeTransport(Self.sessionConfiguration(proxy: proxy, timeout: timeout))
        let bridge = DnsBridge(transport: transport, servers: servers, queryCap: Config.queryCap)
        defer {
            bridge.stop()
            transport.invalidate()
        }

        let json: String
        do {
            let kitTimeout = torOn ? Config.kitTimeoutTorMs : Config.kitTimeoutDirectMs
            // A cancel also stops a bridge whose listener is not ready yet.
            let port = try await bridge.start(timeout: TimeInterval(kitTimeout) / 1000)
            let lookup = kitLookup
            let query = name.query
            // The kit call blocks for up to its timeout. A cancel stops the
            // bridge, and the kit then returns at once.
            json = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: lookup(query, port, kitTimeout))
                    }
                }
            } onCancel: {
                bridge.stop()
            }
        } catch is DnsBridge.StartTimeout {
            return .failure(.timeout)
        } catch {
            return .failure(netError)
        }
        bridge.stop()
        let answered = bridge.answeredCount
        let synthesized = bridge.synthesizedCount

        let result = await MainActor.run {
            OpenAlias.mapAnswer(json: json, synthesizedCount: synthesized, torOn: torOn) { check($0) }
        }
        #if DEBUG
        // The outcome, the time and the counts only: never the name, the
        // records or the address.
        NSLog("[OpenAlias] lookup %@ in %ld ms (answered %ld, synthesized %ld)",
              Self.debugOutcome(result), Int(Date().timeIntervalSince(started) * 1000), answered, synthesized)
        #else
        _ = (started, answered)
        #endif
        return result
    }

    /// `host:port`, split at the last `:`. Nil when it fails to parse.
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

    /// A new ephemeral session for each lookup: no cookies, no cache, no
    /// stored credentials. With Tor on, every request goes through the SOCKS
    /// proxy, which resolves the host names.
    static func sessionConfiguration(proxy: Proxy?, timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        if let proxy {
            configuration.proxyConfigurations = [
                ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host), port: proxy.port)),
            ]
        }
        return configuration
    }

    #if DEBUG
    private static func debugOutcome(_ result: Result<OpenAliasResult, OpenAliasFailure>) -> String {
        switch result {
        case .success(let found): return found.dnssec == .valid ? "resolved, DNSSEC valid" : "resolved, DNSSEC off"
        case .failure(let failure): return "failed, \(failure)"
        }
    }
    #endif
}
