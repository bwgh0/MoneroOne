import Foundation
import LocalAuthentication

@MainActor
class BiometricAuthManager: ObservableObject {
    @Published var biometricType: BiometricType = .none
    @Published var isBiometricEnabled: Bool = false

    enum BiometricType {
        case none
        case touchID
        case faceID

        var displayName: String {
            switch self {
            case .none: return "None"
            case .touchID: return "Touch ID"
            case .faceID: return "Face ID"
            }
        }

        var iconName: String {
            switch self {
            case .none: return "lock"
            case .touchID: return "touchid"
            case .faceID: return "faceid"
            }
        }
    }

    private let biometricEnabledKey = "biometricEnabled"

    init() {
        checkBiometricType()
        loadBiometricSetting()
    }

    private func checkBiometricType() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            biometricType = .none
            return
        }

        switch context.biometryType {
        case .faceID:
            biometricType = .faceID
        case .touchID:
            biometricType = .touchID
        case .opticID:
            biometricType = .faceID // Treat as Face ID for UI purposes
        default:
            biometricType = .none
        }
    }

    private func loadBiometricSetting() {
        isBiometricEnabled = UserDefaults.standard.bool(forKey: biometricEnabledKey)
    }

    func setBiometricEnabled(_ enabled: Bool) {
        isBiometricEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: biometricEnabledKey)
    }

    /// Re-authenticate immediately before moving funds.
    ///
    /// Uses `.deviceOwnerAuthentication` rather than the biometrics-only policy
    /// so the gate still holds on devices with no enrolled biometrics — it falls
    /// back to the device passcode instead of silently passing. Without this,
    /// anyone holding an already-unlocked phone could empty the wallet during
    /// the auto-lock window (5 minutes by default) with no prompt at all.
    func authenticateForTransaction(reason: String = "Confirm this transaction") async -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Device has neither biometrics nor a passcode configured, so there
            // is no stronger check available. Don't lock the owner out of their
            // own funds over it.
            return true
        }

        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    func authenticate(reason: String = "Unlock your wallet") async -> Bool {
        guard biometricType != .none else { return false }

        let context = LAContext()
        context.localizedCancelTitle = "Use PIN"

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success
        } catch {
            return false
        }
    }

    var canUseBiometrics: Bool {
        biometricType != .none
    }
}
