import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Dart-side store for the optional alternate address of a saved network
/// server (SMB / WebDAV). The native server stores only round-trip the fields
/// the dialog knows, so the alternate lives here, keyed `"<source>:<id>"`.
/// Jellyfin does not need this — its servers are pure-Dart JSON and carry
/// `altUrl` directly.
class ServerAltStore {
  ServerAltStore._();

  static const String prefsKey = 'dreamplayer.serverAltAddresses';

  static Future<Map<String, String>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }

  static String _key(String source, String id) => '$source:$id';

  static Future<String?> altFor(String source, String id) async {
    return (await _load())[_key(source, id)];
  }

  /// Sets the alternate address; a null/empty [alt] removes the entry.
  static Future<void> setAlt(String source, String id, String? alt) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _load();
    final k = _key(source, id);
    final a = alt?.trim();
    if (a == null || a.isEmpty) {
      map.remove(k);
    } else {
      map[k] = a;
    }
    await prefs.setString(prefsKey, jsonEncode(map));
  }

  static Future<void> removeFor(String source, String id) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _load();
    if (map.remove(_key(source, id)) != null) {
      await prefs.setString(prefsKey, jsonEncode(map));
    }
  }
}
