import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/ttf_names.dart';
import 'app_debug_log.dart';
import 'file_browser.dart';

/// Resolves a Google Fonts family to a **font file** the native subtitle
/// renderers can register.
///
/// Flutter can render a Google family in the settings preview without any
/// help, but Media3 (`CaptionStyleCompat`), AVFoundation and libass all need
/// either a system family name or a real file. So:
///
///  1. the nine families bundled under `assets/fonts/` are copied out of the
///     asset bundle (offline, and they are what the picker lists first);
///  2. any other family is taken from `google_fonts`' own cache when the
///     preview has already fetched it;
///  3. otherwise the download is triggered and awaited briefly.
///
/// Everything lands in `<app support>/subtitle_fonts/`, one TTF per family, so
/// repeated opens are a file-exists check.
class SubtitleFonts {
  SubtitleFonts._();

  /// Families shipped in the APK/IPA, keyed by their Google Fonts display
  /// name. The asset filenames match `google_fonts`' own convention
  /// (`<Family>-Regular.ttf`), so the package treats them as already
  /// downloaded and the picker previews them with no network at all.
  static const Map<String, String> bundled = {
    'Inter': 'assets/fonts/Inter-Regular.ttf',
    'Open Sans': 'assets/fonts/Open Sans-Regular.ttf',
    'Lato': 'assets/fonts/Lato-Regular.ttf',
    'Montserrat': 'assets/fonts/Montserrat-Regular.ttf',
    'Poppins': 'assets/fonts/Poppins-Regular.ttf',
    'Merriweather': 'assets/fonts/Merriweather-Regular.ttf',
    'Playfair Display': 'assets/fonts/Playfair Display-Regular.ttf',
    'Pacifico': 'assets/fonts/Pacifico-Regular.ttf',
    'Fira Code': 'assets/fonts/Fira Code-Regular.ttf',
  };

  static List<String> get bundledNames => bundled.keys.toList(growable: false);

  /// The full Google Fonts catalog, sorted for the picker.
  static List<String> get onlineFamilies =>
      GoogleFonts.asMap().keys.toList(growable: false)..sort();

  /// The test runner sets this as a process environment variable, not as a
  /// dart-define (same detection as `AppDebugLog`).
  static bool get _isTest => Platform.environment.containsKey('FLUTTER_TEST');

  static String _fileStem(String family) =>
      family.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');

  static final Map<String, Future<String?>> _inFlight = {};

  /// Absolute path to a TTF for [family], or null when it cannot be resolved.
  /// [resolve] never throws — a missing font must not break playback.
  static Future<String?> resolvePath(String? family) {
    if (family == null || family.isEmpty) return Future.value(null);
    return _inFlight.putIfAbsent(
      family,
      () => _resolve(family).whenComplete(() {
        // Block body: `remove` must not return the future itself, or the
        // map value would be awaited by itself (same trap as ThumbnailStore).
        _inFlight.remove(family);
      }),
    );
  }

  /// Ensures the font directory exists and returns it (mpv's `sub-fonts-dir`).
  static Future<String?> directoryPath() async {
    if (_isTest) return null;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/subtitle_fonts');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir.path;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _resolve(String family) async {
    if (_isTest) return null;
    try {
      final dirPath = await directoryPath();
      if (dirPath == null) return null;
      final target = File('$dirPath/${_fileStem(family)}.ttf');
      if (await target.exists() && await target.length() > 0) {
        // A copy made earlier can be wrong (a loose match, a truncated
        // write). Ask the file what it is instead of trusting its name —
        // otherwise one bad copy is reused on every open, forever.
        final names = ttfNameTableNames(await target.readAsBytes());
        if (names.any((n) => fontNameMatches(n, family))) {
          return target.path;
        }
        AppDebugLog.mark(
          'SUBFONT $family -> discarding stale copy (${names.take(3).join(",")})',
        );
        await target.delete();
      }

      final asset = bundled[family];
      if (asset != null) {
        final data = await rootBundle.load(asset);
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        AppDebugLog.mark('SUBFONT $family -> bundled asset');
        return target.path;
      }

      final cached = await _googleFontsCacheFile(family);
      if (cached != null) {
        await cached.copy(target.path);
        AppDebugLog.mark('SUBFONT $family -> cached file');
        return target.path;
      }

      // Previewing the family usually already started this; nudge it and give
      // the download a short window so opening a video right after choosing a
      // font still uses it. `pendingFonts()` is the package's own await for
      // the load it started, so the file is usually there before polling.
      _triggerDownload(family);
      try {
        await GoogleFonts.pendingFonts()
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // Offline / fetch refused: the poll below reports the outcome.
      }
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(deadline)) {
        final fetched = await _googleFontsCacheFile(family);
        if (fetched != null) {
          await fetched.copy(target.path);
          AppDebugLog.mark('SUBFONT $family -> downloaded file');
          return target.path;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      AppDebugLog.mark('SUBFONT $family -> NO FILE (renderer falls back)');
    } catch (error) {
      // Fall through to "no file": the renderer keeps its default font.
      AppDebugLog.mark('SUBFONT $family -> resolve failed: $error');
    }
    return null;
  }

  static void _triggerDownload(String family) {
    try {
      GoogleFonts.getFont(family);
    } catch (_) {}
  }

  /// Lets the user pick a font FILE from device storage (SD card, Files,
  /// iCloud Drive, Downloads) and registers it as the custom subtitle font.
  ///
  /// The picked file is copied into `<app support>/subtitle_fonts/` (a real
  /// path the native renderers can open) and its own `name` table is read for
  /// the display family name — the file name is not a reliable family name.
  /// Returns the registered `{path, displayName}`, or null when the user
  /// cancelled / the copy failed / the file is not a font.
  static Future<({String path, String displayName})?> registerCustomFont() async {
    if (_isTest) return null;
    try {
      final picked = await FileBrowserService.instance.pickFontFile();
      if (picked == null) return null;
      final ext = picked.name.toLowerCase().endsWith('.otf')
          ? '.otf'
          : picked.name.toLowerCase().endsWith('.ttc')
              ? '.ttc'
              : '.ttf';
      final stem = picked.name
          .substring(0, picked.name.length - ext.length)
          .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final dirPath = await directoryPath();
      if (dirPath == null) return null;
      final dest = File('$dirPath/custom_$stem$ext');
      final ok = await FileBrowserService.instance
          .copyFontFile(picked.uri, dest.path);
      if (!ok || !await dest.exists() || await dest.length() == 0) {
        AppDebugLog.mark('SUBFONT custom -> copy failed (${picked.name})');
        return null;
      }
      // Read the family name from the font's own name table; fall back to the
      // file stem. A non-font file yields no names, which we reject.
      final names = ttfNameTableNames(await dest.readAsBytes());
      final display = names.isNotEmpty ? names.first : stem;
      if (names.isEmpty) {
        AppDebugLog.mark('SUBFONT custom -> no name table (${picked.name})');
        await dest.delete();
        return null;
      }
      AppDebugLog.mark('SUBFONT custom -> $display (${dest.path})');
      return (path: dest.path, displayName: display);
    } catch (error) {
      AppDebugLog.mark('SUBFONT custom -> failed: $error');
      return null;
    }
  }

  /// The custom font path is stored directly on `SubtitleStyle` — it is
  /// already a real file, so resolution is just an existence check (the source
  /// provider may be gone, which is why the copy in `registerCustomFont`
  /// matters).
  static Future<String?> customFontPathIfValid(String? path) async {
    if (path == null || path.isEmpty || _isTest) return null;
    try {
      final f = File(path);
      if (await f.exists() && await f.length() > 0) return path;
    } catch (_) {}
    return null;
  }

  /// The `.ttf`/`.otf` files `google_fonts` has cached, whatever they are
  /// called. Downloads land in the app-support directory as
  /// `<Family>_regular_<sha256>.ttf`; the subtitle font copies live one level
  /// down in `subtitle_fonts/`, which is harmless to include.
  static Future<List<File>> _cachedFontFiles() async {
    final out = <File>[];
    try {
      final support = await getApplicationSupportDirectory();
      await for (final entity
          in Directory(support.path).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final lower = entity.path.toLowerCase();
        if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) continue;
        out.add(entity);
        if (out.length >= 400) break;
      }
    } catch (_) {
      // Keep whatever was found: a listing that throws part-way (a sandbox
      // restriction on one entry) must not read as "the cache is empty".
    }
    return out;
  }

  static String _basename(String path) =>
      path.split(Platform.pathSeparator).last;

  /// The cached download for [family].
  ///
  /// Convention first (cheap), then the font's own `name` table. The second
  /// pass is what makes this reliable on iOS: `entity.uri.pathSegments`
  /// percent-encodes spaces, so `Playfair Display_regular_….ttf` never matched
  /// the old prefix check, and any future naming change would silently break
  /// font application again. Asking the file what family it carries cannot.
  static Future<File?> _googleFontsCacheFile(String family) async {
    final files = await _cachedFontFiles();
    if (files.isEmpty) return null;

    final prefix = '${family}_regular_';
    for (final file in files) {
      final name = _basename(file.path);
      if (name.startsWith(prefix) && name.toLowerCase().endsWith('.ttf')) {
        return file;
      }
    }

    File? loose;
    for (final file in files) {
      try {
        final names = ttfNameTableNames(await file.readAsBytes());
        if (!names.any((n) => fontNameMatches(n, family))) continue;
        // Prefer the Regular face when several weights were cached (the
        // picker previews a family by downloading only Regular, so this is
        // normally the only one).
        if (_basename(file.path).toLowerCase().contains('_regular_')) {
          return file;
        }
        loose ??= file;
      } catch (_) {
        continue;
      }
    }
    return loose;
  }
}
