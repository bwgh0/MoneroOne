import XCTest
@testable import MoneroOne

@MainActor
final class BiometricAuthManagerTests: XCTestCase {

    var biometricManager: BiometricAuthManager!

    override func setUp() async throws {
        biometricManager = BiometricAuthManager()
    }

    override func tearDown() async throws {
        biometricManager = nil
    }

    // MARK: - Biometric Type Tests

    func testBiometricTypeEnumCases() async {
        // Test that all enum cases exist
        let types: [BiometricAuthManager.BiometricType] = [.none, .touchID, .faceID]
        XCTAssertEqual(types.count, 3)
    }

    func testBiometricTypeIsNotNil() async {
        // biometricType should always return a valid value
        XCTAssertNotNil(biometricManager.biometricType)
    }

    func testBiometricTypeIsOneOfExpectedTypes() async {
        let validTypes: [BiometricAuthManager.BiometricType] = [.none, .touchID, .faceID]
        XCTAssertTrue(validTypes.contains(biometricManager.biometricType))
    }

    // MARK: - Availability Tests

    func testCanUseBiometricsReturnsBoolean() async {
        // canUseBiometrics should return true only if biometricType is not .none
        let canUse = biometricManager.canUseBiometrics
        let hasType = biometricManager.biometricType != .none

        XCTAssertEqual(canUse, hasType)
    }

    func testCanUseBiometricsFalseWhenNoHardware() async {
        // On simulator without biometric hardware, this should be false
        // (unless running on a device with Face ID/Touch ID)
        if biometricManager.biometricType == .none {
            XCTAssertFalse(biometricManager.canUseBiometrics)
        }
    }

    // MARK: - Display Name Tests

    func testBiometricTypeDisplayName() async {
        let displayName = biometricManager.biometricType.displayName

        switch biometricManager.biometricType {
        case .none:
            XCTAssertEqual(displayName, "None")
        case .touchID:
            XCTAssertEqual(displayName, "Touch ID")
        case .faceID:
            XCTAssertEqual(displayName, "Face ID")
        }
    }

    func testBiometricTypeDisplayNameIsNeverEmpty() async {
        XCTAssertFalse(biometricManager.biometricType.displayName.isEmpty)
    }

    // MARK: - Icon Tests

    func testBiometricTypeIconName() async {
        let iconName = biometricManager.biometricType.iconName

        switch biometricManager.biometricType {
        case .none:
            XCTAssertEqual(iconName, "lock")
        case .touchID:
            XCTAssertEqual(iconName, "touchid")
        case .faceID:
            XCTAssertEqual(iconName, "faceid")
        }
    }

    func testBiometricTypeIconNameIsValidSFSymbol() async {
        let validIcons = ["lock", "touchid", "faceid"]
        XCTAssertTrue(validIcons.contains(biometricManager.biometricType.iconName))
    }

    // MARK: - Authentication Tests

    func testAuthenticateReturnsBoolean() async {
        // Note: Actual authentication will fail in tests/simulator
        // We're just testing that the method returns without crashing
        let result = await biometricManager.authenticate(reason: "Test authentication")
        XCTAssertNotNil(result)
    }

    func testAuthenticateWithEmptyReasonDoesNotCrash() async {
        let result = await biometricManager.authenticate(reason: "")
        // Should still return a result (likely false due to lack of biometrics in simulator)
        XCTAssertFalse(result)
    }
}
