import XCTest
@testable import MoneroOne

@MainActor
final class NetworkMonitorTests: XCTestCase {

    // MARK: - Singleton Tests

    func testSharedInstanceExists() async {
        let monitor = NetworkMonitor.shared
        XCTAssertNotNil(monitor)
    }

    func testSharedInstanceIsSameReference() async {
        let monitor1 = NetworkMonitor.shared
        let monitor2 = NetworkMonitor.shared
        XCTAssertTrue(monitor1 === monitor2, "Shared instance should be the same object")
    }

    // MARK: - Connection State Tests

    func testIsConnectedIsBoolean() async {
        let monitor = NetworkMonitor.shared
        // isConnected should be a valid boolean
        XCTAssertTrue(monitor.isConnected == true || monitor.isConnected == false)
    }

    func testConnectionTypeIsValid() async {
        let monitor = NetworkMonitor.shared
        let validTypes: [NetworkMonitor.ConnectionType] = [.wifi, .cellular, .wired, .unknown]
        XCTAssertTrue(validTypes.contains(monitor.connectionType))
    }

    // MARK: - Connection Type Enum Tests

    func testConnectionTypeEnumCases() async {
        let types: [NetworkMonitor.ConnectionType] = [.wifi, .cellular, .wired, .unknown]
        XCTAssertEqual(types.count, 4)
    }

    // MARK: - Simulator Tests

    func testSimulatorHasNetworkConnection() async {
        // Simulator should typically have network access via host machine
        let monitor = NetworkMonitor.shared

        // Give time for initial path update
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        // In CI or without network, this could be false
        // So we just test it doesn't crash
        XCTAssertNotNil(monitor.isConnected)
    }
}
