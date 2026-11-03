import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/adult_content_store.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:dream_player/utils/image_size.dart';
import 'package:dream_player/widgets/cached_image.dart';

/// Issue #58: adult JAV posters are full DVD sleeves (wider than tall);
/// with the adult toggle on, poster cards must crop to the RIGHT (front
/// cover), and posters are fetched at w500 so they stay sharp.

Uint8List _png(int w, int h) {
  final b = Uint8List(24);
  b[0] = 0x89;
  b[1] = 0x50;
  b[2] = 0x4E;
  b[3] = 0x47;
  b[16] = (w >> 24) & 0xFF;
  b[17] = (w >> 16) & 0xFF;
  b[18] = (w >> 8) & 0xFF;
  b[19] = w & 0xFF;
  b[20] = (h >> 24) & 0xFF;
  b[21] = (h >> 16) & 0xFF;
  b[22] = (h >> 8) & 0xFF;
  b[23] = h & 0xFF;
  return b;
}

Uint8List _jpeg(int w, int h) {
  // FF D8, APP0 segment (16 bytes), then SOF0: FF C0 len(8) precision(8) h w.
  final b = Uint8List(2 + 2 + 16 + 2 + 2 + 1 + 2 + 2);
  var i = 0;
  b[i++] = 0xFF;
  b[i++] = 0xD8;
  b[i++] = 0xFF;
  b[i++] = 0xE0; // APP0
  b[i++] = 0x00;
  b[i++] = 0x10; // length 16
  i += 14;
  b[i++] = 0xFF;
  b[i++] = 0xC0; // SOF0
  b[i++] = 0x00;
  b[i++] = 0x08;
  b[i++] = 0x08; // precision
  b[i++] = (h >> 8) & 0xFF;
  b[i++] = h & 0xFF;
  b[i++] = (w >> 8) & 0xFF;
  b[i++] = w & 0xFF;
  return b;
}

void main() {
  test('imageSizeOf reads PNG, JPEG, GIF and WebP headers', () {
    expect(imageSizeOf(_png(500, 750)), isNotNull);
    expect(imageSizeOf(_png(500, 750))!.isWide, isFalse);
    expect(imageSizeOf(_png(1000, 700))!.isWide, isTrue);

    final jpg = imageSizeOf(_jpeg(1000, 700));
    expect(jpg, isNotNull);
    expect(jpg!.width, 1000);
    expect(jpg.height, 700);
    expect(jpg.isWide, isTrue);

    final gif = Uint8List(24);
    gif[0] = 0x47;
    gif[1] = 0x49;
    gif[2] = 0x46;
    gif[6] = 0xE8;
    gif[7] = 0x03; // 1000
    gif[8] = 0xBC;
    gif[9] = 0x02; // 700
    expect(imageSizeOf(gif)!.isWide, isTrue);

    expect(imageSizeOf(Uint8List(4)), isNull);
    expect(imageSizeOf(Uint8List(30)), isNull);
  });

  test('posterAlignment: wide poster + adult on -> right (front cover)', () {
    final wide = _png(1000, 700);
    expect(
      posterAlignment(
          poster: true, adult: true, bytes: wide) == Alignment.centerRight,
      isTrue,
    );
  });

  test('posterAlignment: adult OFF keeps centre crop even for wide images', () {
    expect(
      posterAlignment(poster: true, adult: false, bytes: _png(1000, 700)) ==
          Alignment.center,
      isTrue,
    );
  });

  test('posterAlignment: tall poster stays centred in adult mode', () {
    expect(
      posterAlignment(poster: true, adult: true, bytes: _png(500, 750)) ==
          Alignment.center,
      isTrue,
    );
  });

  test('posterAlignment: explicit alignment and non-poster images win', () {
    expect(
      posterAlignment(
        explicitAlignment: Alignment.topCenter,
        poster: true,
        adult: true,
        bytes: _png(1000, 700),
      ) == Alignment.topCenter,
      isTrue,
    );
    expect(
      posterAlignment(poster: false, adult: true, bytes: _png(1000, 700)) ==
          Alignment.center,
      isTrue,
    );
    expect(
      posterAlignment(poster: true, adult: true, bytes: null) ==
          Alignment.center,
      isTrue,
    );
  });

  test('adult store publishes its value synchronously for card renderers',
      () async {
    SharedPreferences.setMockInitialValues({includeAdultPrefsKey: true});
    final store = AdultContentStore();
    expect(AdultContentStore.includeAdultNow, isFalse);
    await store.load();
    expect(AdultContentStore.includeAdultNow, isTrue);
    await store.setIncludeAdult(false);
    expect(AdultContentStore.includeAdultNow, isFalse);
    SharedPreferences.setMockInitialValues({});
  });

  test('posterUrlOf asks TMDB for w500 (issue #58 sharpness)', () {
    expect(posterUrlOf(null), isNull);
    final meta = TmdMeta(
      movie: TmdMovie(
        id: 1,
        title: 't',
        posterPath: '/abc.jpg',
        provider: MetadataProvider.tmdb,
        providerId: '1',
      ),
    );
    expect(posterUrlOf(meta), contains('/t/p/w500/'));
  });
}
