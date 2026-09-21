import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Simple IAP debug logger that appends to Documents/DreamPlayer/iap_debug.log.
/// Visible in the Files app on iOS (On My iPad → DreamPlayer → iap_debug.log).
class IapLog {
  IapLog._();
  static final IapLog instance = IapLog._();

  File? _file;
  bool _initialized = false;

  Future<void> _init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/iap_debug.log');
      // Write header on first init
      if (!await _file!.exists()) {
        await _file!.writeAsString('=== IAP Debug Log ===\n');
      }
    } catch (_) {}
  }

  Future<void> log(String tag, String message) async {
    await _init();
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] [$tag] $message\n';
    debugPrint('[IAP] $tag: $message');
    try {
      await _file?.writeAsString(line, mode: FileMode.append);
    } catch (_) {}
  }

  /// Clear the log file.
  Future<void> clear() async {
    await _init();
    try {
      await _file?.writeAsString('=== IAP Debug Log (cleared) ===\n');
    } catch (_) {}
  }

  /// Get the full log content (for reading back).
  Future<String> readAll() async {
    await _init();
    try {
      return await _file?.readAsString() ?? '(empty)';
    } catch (_) {
      return '(error reading log)';
    }
  }
}
