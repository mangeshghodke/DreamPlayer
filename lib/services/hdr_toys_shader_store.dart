import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The hdr-toys profiles we ship, with the shader chain each one uses.
///
/// hdr-toys (MIT, https://github.com/natural-harmonia-gropius/hdr-toys) is a
/// set of libplacebo user shaders for mpv's `vo=gpu-next`. The chains below
/// are the upstream `hdr-toys.conf` profiles, reduced to the shaders those
/// profiles actually use:
///
///  * PQ (BT.2100 PQ / HDR10) - inverse PQ → astra tone-map → gamut → BT.1886
///  * HLG (BT.2100 HLG)        - inverse HLG → astra tone-map → gamut → BT.1886
///  * BT.2020                  - inverse BT.1886 → gamut → BT.1886
///
/// **The `auto_exposure_limit_positive` option upstream appends to astra is
/// deliberately not set.** mpv's `glsl-shader-opts` is a per-shader list
/// indexed against the chain, and a mis-aligned entry makes the shader fail
/// to compile - which means a black picture. astra's own default (no positive
/// exposure limit) is the safer starting point; revisit only if a device
/// test shows blown-out highlights.
enum HdrToysProfile {
  pq('pq', 'BT.2100 PQ (HDR10)', <String>[
    'assets/hdr_toys/clip_both.glsl',
    'assets/hdr_toys/pq_inv.glsl',
    'assets/hdr_toys/astra.glsl',
    'assets/hdr_toys/bottosson.glsl',
    'assets/hdr_toys/bt1886.glsl',
  ]),
  hlg('hlg', 'BT.2100 HLG', <String>[
    'assets/hdr_toys/clip_both.glsl',
    'assets/hdr_toys/hlg_inv.glsl',
    'assets/hdr_toys/astra.glsl',
    'assets/hdr_toys/bottosson.glsl',
    'assets/hdr_toys/bt1886.glsl',
  ]),
  bt2020('bt2020', 'BT.2020', <String>[
    'assets/hdr_toys/bt1886_inv.glsl',
    'assets/hdr_toys/bottosson.glsl',
    'assets/hdr_toys/bt1886.glsl',
  ]);

  const HdrToysProfile(this.value, this.label, this.assetPaths);

  final String value;
  final String label;
  final List<String> assetPaths;
}

/// Copies the bundled hdr-toys shaders out of the asset bundle and hands
/// back their real paths.
///
/// mpv loads user shaders from the filesystem, so an asset path
/// (`assets/...`) is useless to it - the files have to exist on disk. Same
/// approach as the Anime4K shader store.
class HdrToysShaderStore {
  HdrToysShaderStore._();

  static const String version = 'hdr-toys-2026-10';
  static const List<String> assetPaths = <String>[
    'assets/hdr_toys/clip_both.glsl',
    'assets/hdr_toys/pq_inv.glsl',
    'assets/hdr_toys/hlg_inv.glsl',
    'assets/hdr_toys/bt1886_inv.glsl',
    'assets/hdr_toys/astra.glsl',
    'assets/hdr_toys/bottosson.glsl',
    'assets/hdr_toys/bt1886.glsl',
  ];

  static Future<List<String>>? _paths;

  static Future<List<String>> paths() {
    return _paths ??= _prepare();
  }

  /// Drops the cached paths - the copy lives in the app-support directory, so
  /// a test that deletes that directory needs a fresh copy.
  @visibleForTesting
  static void resetForTest() {
    _paths = null;
  }

  /// The real filesystem paths of one profile's shader chain, in order.
  static Future<List<String>> pathsFor(HdrToysProfile profile) async {
    final allPaths = await paths();
    final byName = <String, String>{
      for (final path in allPaths)
        path.split(Platform.pathSeparator).last: path,
    };
    return [
      for (final assetPath in profile.assetPaths)
        byName[assetPath.split('/').last]!,
    ];
  }

  static Future<List<String>> _prepare() async {
    // `root.path` needs the braces or a local: `$root.path` interpolates the
    // Directory OBJECT (its toString) and then the literal text ".path",
    // which builds a garbage path. The analyzer's "unnecessary braces" lint
    // is wrong about property access - trust the braces.
    final rootPath = (await getApplicationSupportDirectory()).path;
    final separator = Platform.pathSeparator;
    final directory = Directory('$rootPath$separator$version');
    await directory.create(recursive: true);
    final paths = <String>[];
    for (final assetPath in assetPaths) {
      final fileName = assetPath.split('/').last;
      final file = File('${directory.path}$separator$fileName');
      if (!await file.exists()) {
        final source = await rootBundle.loadString(assetPath);
        await file.writeAsString(source, flush: true);
      }
      paths.add(file.path);
    }
    return paths;
  }
}
