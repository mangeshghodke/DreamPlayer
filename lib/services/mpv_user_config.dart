import 'package:shared_preferences/shared_preferences.dart';

import '../utils/mpv_interpolation.dart' show MpvOption;

/// Options a user's `mpv.conf` must NOT override: they are what keeps the
/// video SurfaceView attached and the app's own hardening intact. The
/// SurfaceView attach sequence re-asserts `vo`/`wid`/`force-window` on every
/// attach anyway, but the values are filtered out here so a conf cannot flip
/// them even between attaches.
const Set<String> mpvProtectedOptions = {
  'vo',
  'wid',
  'force-window',
  'gpu-context',
  'config',
  'config-dir',
  'input-conf',
  'load-scripts',
  'script',
  'scripts-append',
};

/// Init-only options: libmpv reads these only during `mpv_initialize`, so
/// applying them at runtime is a silent no-op. They are reported as skipped
/// rather than applied.
const Set<String> mpvInitOnlyOptions = {
  'config',
  'config-dir',
  'input-conf',
  'load-scripts',
  'script',
  'scripts-append',
  'player-operation-mode',
};

/// Result of parsing an mpv config file.
class MpvConfParseResult {
  const MpvConfParseResult({
    required this.options,
    required this.warnings,
  });

  /// Parsed options in file order, minus protected/init-only keys (those are
  /// counted in [warnings]).
  final List<MpvOption> options;

  /// Human-readable notes: skipped profile sections, failed includes,
  /// protected keys, unparseable lines.
  final List<String> warnings;
}

/// Parses mpv.conf syntax: `#` comments, blank lines, `key=value`,
/// `no-key` (→ `key=no`), bare `key` (→ `key=yes`), quoted values, and
/// `include=path` (resolved through [includeFiles], keyed by path relative to
/// [baseDir]; depth-capped). `[profile]` sections are skipped with a warning.
///
/// Pure and synchronous — file IO happens in the caller, which passes the
/// included files' contents via [includeFiles] (tests pass a map).
MpvConfParseResult parseMpvConf(
  String content, {
  String? baseDir,
  Map<String, String>? includeFiles,
  int depth = 0,
}) {
  final options = <MpvOption>[];
  final warnings = <String>[];
  var inProfile = false;

  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    if (line.startsWith('[') && line.endsWith(']')) {
      inProfile = true;
      warnings.add('profile section ${line.substring(1, line.length - 1)} skipped');
      continue;
    }
    if (inProfile) continue;

    String key;
    String value;
    final eq = line.indexOf('=');
    if (eq >= 0) {
      key = line.substring(0, eq).trim();
      value = _unquote(line.substring(eq + 1).trim());
    } else if (line.startsWith('no-')) {
      key = line.substring(3).trim();
      value = 'no';
    } else {
      key = line.trim();
      value = 'yes';
    }
    if (key.isEmpty) continue;

    if (key == 'include') {
      if (depth >= 5) {
        warnings.add('include "$value" skipped (depth cap)');
        continue;
      }
      var incPath = value;
      if (baseDir != null && !_isAbsolute(incPath)) {
        incPath = '$baseDir/$incPath';
      }
      final inc = includeFiles?[incPath];
      if (inc == null) {
        warnings.add('include "$value" not readable, skipped');
        continue;
      }
      final sub = parseMpvConf(
        inc,
        baseDir: baseDir,
        includeFiles: includeFiles,
        depth: depth + 1,
      );
      options.addAll(sub.options);
      warnings.addAll(sub.warnings.map((w) => 'include "$value": $w'));
      continue;
    }

    if (mpvInitOnlyOptions.contains(key) || mpvProtectedOptions.contains(key)) {
      warnings.add('"$key" is init-only/protected, skipped');
      continue;
    }
    options.add(MpvOption(key, value));
  }
  return MpvConfParseResult(options: options, warnings: warnings);
}

String _unquote(String v) {
  if (v.length >= 2 &&
      ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'")))) {
    return v.substring(1, v.length - 1);
  }
  return v;
}

bool _isAbsolute(String p) =>
    p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);

/// Persisted pointer to the user's custom mpv config file (a persistable
/// content:// URI on Android). Empty = none.
class MpvUserConfigStore {
  static const uriKey = 'dreamplayer.mpvUserConfigUri';
  static const nameKey = 'dreamplayer.mpvUserConfigName';

  static Future<({String? uri, String? name})> load() async {
    final prefs = await SharedPreferences.getInstance();
    final uri = prefs.getString(uriKey);
    if (uri == null || uri.isEmpty) return (uri: null, name: null);
    return (uri: uri, name: prefs.getString(nameKey) ?? uri);
  }

  static Future<void> save({required String uri, required String name}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(uriKey, uri);
    await prefs.setString(nameKey, name);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(uriKey);
    await prefs.remove(nameKey);
  }
}
