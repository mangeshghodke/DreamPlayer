import 'package:flutter_test/flutter_test.dart';
import 'package:dream_player/services/anime4k_shader_store.dart';

void main() {
  test('uses the pinned Anime4K fast shader set', () {
    expect(Anime4kShaderStore.version, 'v4.0.1');
    expect(Anime4kShaderStore.assetPaths, hasLength(9));
    expect(Anime4kMode.values.map((mode) => mode.label), [
      'Mode A',
      'Mode B',
      'Mode C',
      'Mode A+A',
      'Mode B+B',
      'Mode C+A',
    ]);
    expect(Anime4kMode.a.assetPaths, hasLength(5));
    expect(Anime4kMode.aa.assetPaths, hasLength(6));
  });

  test('accepts SDR video parameters', () {
    expect(isAnime4kSdrVideo(colorMatrix: 'bt709', gamma: 'bt1886'), isTrue);
  });

  test('rejects HDR and Dolby Vision parameters', () {
    expect(isAnime4kSdrVideo(gamma: 'pq'), isFalse);
    expect(isAnime4kSdrVideo(gamma: 'hlg'), isFalse);
    expect(isAnime4kSdrVideo(colorMatrix: 'dolbyvision'), isFalse);
    expect(
      isAnime4kSdrVideo(colorMatrix: 'bt2020nc', gamma: 'bt1886', sigPeak: 4),
      isFalse,
    );
  });

  test('allows Anime4K up to 1440p', () {
    expect(
      isAnime4kSupportedResolution(width: 1920, height: 1080),
      isTrue,
    );
    expect(
      isAnime4kSupportedResolution(width: 2560, height: 1440),
      isTrue,
    );
  });

  test('refuses Anime4K on 4K and 8K sources', () {
    expect(
      isAnime4kSupportedResolution(width: 3840, height: 2160),
      isFalse,
    );
    expect(
      isAnime4kSupportedResolution(width: 4096, height: 2160),
      isFalse,
    );
    expect(
      isAnime4kSupportedResolution(width: 7680, height: 4320),
      isFalse,
    );
  });

  test('judges the vertical video by pixel count, not by dimension', () {
    // 1080x2160 is the same pixel count as 1920x1080 - fine.
    expect(
      isAnime4kSupportedResolution(width: 1080, height: 2160),
      isTrue,
    );
    // 2160x3840 (vertical 4K) is not.
    expect(
      isAnime4kSupportedResolution(width: 2160, height: 3840),
      isFalse,
    );
  });

  test('allows an unknown size - it means "not measured yet"', () {
    expect(isAnime4kSupportedResolution(), isTrue);
    expect(isAnime4kSupportedResolution(width: 1920), isTrue);
    expect(isAnime4kSupportedResolution(width: 0, height: 0), isTrue);
  });
}
