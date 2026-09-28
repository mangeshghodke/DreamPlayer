import Foundation
import Flutter
import Security

/// Persists the trial start time in the iOS Keychain so it survives
/// restart, app deletion AND reinstall (anti free-trial-abuse).
///
/// The item is written with `kSecAttrSynchronizable: true`, so it also
/// follows the user to a new device through iCloud Keychain / an encrypted
/// backup — without that, buying a new phone and restoring a backup would
/// hand out a fresh 7-day trial. If iCloud Keychain is unavailable the write
/// falls back to a device-local item, so the marker is never silently lost.
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
    // Preferred: the iCloud-synced item.
    if let synced = readItem(synchronizable: true) { return synced }
    // Migration: builds before the sync shipped stored a device-local
    // (`ThisDeviceOnly`) item under the same service/account. It is invisible
    // to a `kSecAttrSynchronizable: true` query, so read it explicitly and
    // re-write it as synced — otherwise every existing user keeps a
    // device-only trial marker forever.
    guard let legacy = readItem(synchronizable: false) else { return nil }
    write(legacy)
    return legacy
  }

  private static func readItem(synchronizable: Bool) -> Int64? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: synchronizable,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return data.withUnsafeBytes { $0.load(as: Int64.self) }
  }

  private static func write(_ value: Int64?) {
    // Delete any existing copy — both the synced item and the legacy
    // device-local one, so a value never lingers as a second entry.
    for synchronizable in [true, false] {
      SecItemDelete(deleteQuery(synchronizable: synchronizable) as CFDictionary)
    }

    guard let value = value else { return }
    var val = value
    let data = Data(bytes: &val, count: MemoryLayout<Int64>.size)

    // Prefer the iCloud-synced item: the trial marker then follows the user to
    // a new device (or a new phone restored from backup) instead of handing
    // out a fresh 7 days.
    var syncedQuery = addQuery(data: data, synchronizable: true)
    if SecItemAdd(syncedQuery as CFDictionary, nil) == errSecSuccess { return }

    // iCloud Keychain unavailable (user signed out, Keychain sync off, no
    // iCloud account) — fall back to a device-local item so the marker is
    // still recorded. Without this the trial start would be lost entirely.
    syncedQuery = addQuery(data: data, synchronizable: false)
    SecItemAdd(syncedQuery as CFDictionary, nil)
  }

  private static func deleteQuery(synchronizable: Bool) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: synchronizable,
    ]
  }

  private static func addQuery(data: Data, synchronizable: Bool) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      // Readable after the first unlock following a boot (background-safe).
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
      kSecAttrSynchronizable as String: synchronizable,
    ]
  }
}
