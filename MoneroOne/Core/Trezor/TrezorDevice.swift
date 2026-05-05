import CoreBluetooth
import Foundation

/// Represents a discovered Trezor Safe 7 device
struct TrezorDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let peripheral: CBPeripheral

    static func == (lhs: TrezorDevice, rhs: TrezorDevice) -> Bool {
        lhs.id == rhs.id
    }
}
