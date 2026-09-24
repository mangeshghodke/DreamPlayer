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
}
