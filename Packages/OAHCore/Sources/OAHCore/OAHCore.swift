import Foundation
import OAHMobile

public struct OAHError: Error, LocalizedError {
  public let code: String
  public var errorDescription: String? { code }
}

/// Runs the existing Rust verifier. Only public addresses and signed records
/// cross the boundary; private wallet keys remain in MoneroKit.
public enum OAHCore {
  public static func call(_ request: [String: Any]) throws -> [String: Any] {
    let input = try JSONSerialization.data(withJSONObject: request)
    let pointer = input.withUnsafeBytes { bytes in
      oah_mobile_call(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
    }
    guard let pointer else { throw OAHError(code: "mobile.internal") }
    defer { oah_mobile_free(pointer) }
    let data = Data(String(cString: pointer).utf8)
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OAHError(code: "mobile.bad_response")
    }
    if let code = result["error"] as? String { throw OAHError(code: code) }
    guard let value = result["ok"] as? [String: Any] else {
      throw OAHError(code: "mobile.bad_response")
    }
    return value
  }
}
