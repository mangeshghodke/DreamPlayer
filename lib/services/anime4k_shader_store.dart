import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

bool isAnime4kSdrVideo({String? colorMatrix, String? gamma, double? sigPeak}) {
  final matrix = colorMatrix?.trim().toLowerCase() ?? '';
  final transfer = gamma?.trim().toLowerCase() ?? '';
  if (matrix == 'dolbyvision' || transfer == 'pq' || transfer == 'hlg') {
    return false;
  }
  if (sigPeak != null && sigPeak > 1.0 && matrix.contains('2020')) {
    return false;
  }
  return true;
}

/// Largest frame Anime4K is allowed to run on: 2560×1440 (≈3.7 MP).
///
/// Anime4K upscales *up* - on a 4K/8K source there is nothing to upscale, and
/// the chain would be paid per frame at 4K on a phone GPU, which is exactly
/// how a shader chain turns into dropped frames and heat. The guard is on the
/// **pixel count**, not on each dimension: a vertical 1080×2160 clip has the
/// same pixel count as 1920×1080 and is fine, while 3840×2160 is not.
const int anime4kMaxPixels = 2560 * 1440;

/// Whether a source of this size may run the Anime4K chain.
///
/// Unknown size (null) is allowed: the caller only enables Anime4K once mpv
/// has reported `VideoParams`, so "unknown" means "not measured yet", not
/// "measured as huge".
bool isAnime4kSupportedResolution({int? width, int? height}) {
  if (width == null || height == null) return true;
  if (width <= 0 || height <= 0) return true;
  return width * height <= anime4kMaxPixels;
}

enum Anime4kMode { a, b, c, aa, bb, ca }

extension Anime4kModeDetails on Anime4kMode {
  String get label {
    return switch (this) {
      Anime4kMode.a => 'Mode A',
      Anime4kMode.b => 'Mode B',
      Anime4kMode.c => 'Mode C',
      Anime4kMode.aa => 'Mode A+A',
      Anime4kMode.bb => 'Mode B+B',
      Anime4kMode.ca => 'Mode C+A',
    };
  }

  String get description {
    return switch (this) {
      Anime4kMode.a => '1080p · balanced',
      Anime4kMode.b => '720p · softer',
      Anime4kMode.c => 'clean · low artifacts',
      Anime4kMode.aa => '1080p · strongest',
      Anime4kMode.bb => '720p · stronger',
      Anime4kMode.ca => 'clean + restore',
    };
  }

  List<String> get assetPaths {
    const restoreM = 'assets/anime4k/Anime4K_Restore_CNN_M.glsl';
    const restoreS = 'assets/anime4k/Anime4K_Restore_CNN_S.glsl';
    const restoreSoftM = 'assets/anime4k/Anime4K_Restore_CNN_Soft_M.glsl';
    const restoreSoftS = 'assets/anime4k/Anime4K_Restore_CNN_Soft_S.glsl';
    const upscaleM = 'assets/anime4k/Anime4K_Upscale_CNN_x2_M.glsl';
    const upscaleS = 'assets/anime4k/Anime4K_Upscale_CNN_x2_S.glsl';
    const upscaleDenoiseM =
        'assets/anime4k/Anime4K_Upscale_Denoise_CNN_x2_M.glsl';
    const auto2 = 'assets/anime4k/Anime4K_AutoDownscalePre_x2.glsl';
    const auto4 = 'assets/anime4k/Anime4K_AutoDownscalePre_x4.glsl';
    return switch (this) {
      Anime4kMode.a => [restoreM, upscaleM, auto2, auto4, upscaleS],
      Anime4kMode.b => [restoreSoftM, upscaleM, auto2, auto4, upscaleS],
      Anime4kMode.c => [upscaleDenoiseM, auto2, auto4, upscaleS],
      Anime4kMode.aa => [restoreM, upscaleM, auto2, auto4, restoreS, upscaleS],
      Anime4kMode.bb => [
        restoreSoftM,
        upscaleM,
        auto2,
        auto4,
        restoreSoftS,
        upscaleS,
      ],
      Anime4kMode.ca => [upscaleDenoiseM, auto2, auto4, restoreM, upscaleS],
    };
  }
}

class Anime4kShaderStore {
  Anime4kShaderStore._();

  static const version = 'v4.0.1';
  static const assetPaths = <String>[
    'assets/anime4k/Anime4K_Restore_CNN_M.glsl',
    'assets/anime4k/Anime4K_Restore_CNN_S.glsl',
    'assets/anime4k/Anime4K_Restore_CNN_Soft_M.glsl',
    'assets/anime4k/Anime4K_Restore_CNN_Soft_S.glsl',
    'assets/anime4k/Anime4K_Upscale_CNN_x2_M.glsl',
    'assets/anime4k/Anime4K_Upscale_CNN_x2_S.glsl',
    'assets/anime4k/Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'assets/anime4k/Anime4K_AutoDownscalePre_x2.glsl',
    'assets/anime4k/Anime4K_AutoDownscalePre_x4.glsl',
  ];

  static Future<List<String>>? _paths;

  static Future<List<String>> paths() {
    return _paths ??= _prepare();
  }

  static Future<List<String>> pathsFor(Anime4kMode mode) async {
    final allPaths = await paths();
    final byName = <String, String>{
      for (final path in allPaths)
        path.split(Platform.pathSeparator).last: path,
    };
    return [
      for (final assetPath in mode.assetPaths)
        byName[assetPath.split('/').last]!,
    ];
  }

  static Future<List<String>> _prepare() async {
    final root = await getApplicationSupportDirectory();
    final separator = Platform.pathSeparator;
    final directory = Directory('${root.path}${separator}anime4k_$version');
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
