import Foundation
import Flutter
import Security

/// Persists the trial start time in the iOS Keychain so it survives
/// restart AND reinstall (anti free-trial-abuse).
class TrialStore {
  private static let service = "com.dreamplayer.app.trial"
  private static let account = "trialStartedAt"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "dreamplayer/trial",
      binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getTrialStartedAt":
        result(read())
      case "setTrialStartedAt":
        let ms = call.arguments as? Int64
        write(ms)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func read() -> Int64? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return data.withUnsafeBytes { $0.load(as: Int64.self) }
  }

  private static func write(_ value: Int64?) {
    // Delete existing
    let delQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(delQuery as CFDictionary)

    guard let value = value else { return }
    // Write new
    var val = value
    let data = Data(bytes: &val, count: MemoryLayout<Int64>.size)
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemAdd(addQuery as CFDictionary, nil)
  }
}
