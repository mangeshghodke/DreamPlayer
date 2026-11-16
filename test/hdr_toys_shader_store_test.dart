import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/hdr_toys_shader_store.dart';
import 'package:dream_player/services/tone_map_store.dart';
import 'package:dream_player/utils/mpv_hdr_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider is a plugin, so the copy target is mocked to a temp dir.
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDir;

  setUp(() async {
    supportDir = await Directory.systemTemp.createTemp('dreamplayer_hdr');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return supportDir.path;
          }
          return null;
        });
    HdrToysShaderStore.resetForTest();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    HdrToysShaderStore.resetForTest();
    if (supportDir.existsSync()) {
      supportDir.deleteSync(recursive: true);
    }
  });

  test('the shaders are copied to real files inside the support dir', () async {
    // Regression: the copy used `'$root.path$separator$version'`, and Dart
    // interpolates `$root` (the Directory OBJECT) and then the literal text
    // ".path" - so the directory was created under a garbage relative path
    // and every profile failed with "Could not load shaders".
    final paths = await HdrToysShaderStore.pathsFor(HdrToysProfile.pq);
    expect(paths, hasLength(HdrToysProfile.pq.assetPaths.length));
    for (final path in paths) {
      expect(path, startsWith(supportDir.path));
      expect(path, isNot(contains('Directory:')));
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    expect(paths.last.endsWith('bt1886.glsl'), isTrue);
  });

  test('every profile copies its own chain to disk', () async {
    for (final profile in HdrToysProfile.values) {
      HdrToysShaderStore.resetForTest();
      final paths = await HdrToysShaderStore.pathsFor(profile);
      expect(paths, hasLength(profile.assetPaths.length), reason: profile.value);
      for (final path in paths) {
        expect(File(path).existsSync(), isTrue, reason: '$profile: $path');
      }
    }
  });

  test('the hdr-toys profiles carry the upstream shader chains', () {
    expect(
      HdrToysProfile.pq.assetPaths.map((p) => p.split('/').last).toList(),
      [
        'clip_both.glsl',
        'pq_inv.glsl',
        'astra.glsl',
        'bottosson.glsl',
        'bt1886.glsl',
      ],
    );
    expect(
      HdrToysProfile.hlg.assetPaths.map((p) => p.split('/').last).toList(),
      [
        'clip_both.glsl',
        'hlg_inv.glsl',
        'astra.glsl',
        'bottosson.glsl',
        'bt1886.glsl',
      ],
    );
    expect(
      HdrToysProfile.bt2020.assetPaths.map((p) => p.split('/').last).toList(),
      ['bt1886_inv.glsl', 'bottosson.glsl', 'bt1886.glsl'],
    );
  });

  test('every shader a profile uses is bundled in the store', () {
    final bundled = HdrToysShaderStore.assetPaths.toSet();
    for (final profile in HdrToysProfile.values) {
      for (final assetPath in profile.assetPaths) {
        expect(
          bundled,
          contains(assetPath),
          reason: '${profile.value} uses a shader the store does not copy',
        );
      }
    }
  });

  test('the shader modes are the ones that need gpu-next', () {
    expect(ToneMapMode.pq.usesHdrToysShaders, isTrue);
    expect(ToneMapMode.hlg.usesHdrToysShaders, isTrue);
    expect(ToneMapMode.bt2020.usesHdrToysShaders, isTrue);
    expect(ToneMapMode.sdr.usesHdrToysShaders, isFalse);
    expect(ToneMapMode.native.usesHdrToysShaders, isFalse);
    expect(ToneMapMode.linear.usesHdrToysShaders, isFalse);
  });

  test('the hdr-toys modes let the shaders own the transfer function', () {
    for (final mode in [
      ToneMapMode.pq,
      ToneMapMode.hlg,
      ToneMapMode.bt2020,
    ]) {
      final properties = mpvHdrProperties(mode);
      // The GLSL chain does the work: no second HDR transform on top of it.
      expect(properties['target-colorspace-hint'], 'no', reason: mode.value);
      expect(properties['tone-mapping'], 'clip', reason: mode.value);
      expect(properties['gamut-mapping-mode'], 'clip', reason: mode.value);
      expect(properties['inverse-tone-mapping'], 'no', reason: mode.value);
      expect(properties['target-prim'], 'bt.2020', reason: mode.value);
    }
    expect(mpvHdrProperties(ToneMapMode.pq)['target-trc'], 'pq');
    expect(mpvHdrProperties(ToneMapMode.hlg)['target-trc'], 'hlg');
    expect(mpvHdrProperties(ToneMapMode.bt2020)['target-trc'], 'bt.1886');
  });

  test('the shader modes still write the complete property set', () {
    for (final mode in ToneMapMode.values) {
      expect(
        mpvHdrProperties(mode).keys.toSet(),
        mpvHdrOwnedProperties.toSet(),
        reason: 'mode ${mode.value} must write every owned property',
      );
    }
  });

  test('the stored mode round-trips every value', () {
    for (final mode in ToneMapMode.values) {
      expect(ToneMapMode.fromString(mode.value), mode);
    }
  });
}
