import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/utils/mpv_http_headers.dart';

/// Pins the **libmpv remote-http fix**.
///
/// ## The bug
///
/// A remote `https://` stream that Media3 played fine was refused by the
/// MPV engine with *"Failed to open https://…"*. Two independent causes:
///
///  1. **Different HTTP stacks.** Media3 uses OkHttp (Conscrypt TLS,
///     `User-Agent: okhttp/4.x`); libmpv uses ffmpeg's own http protocol
///     (bundled mbedtls, `User-Agent: Lavf/63.1.100`). The reported host was
///     Cloudflare-fronted with a client-bound `?selection=` token — `Lavf/…`
///     is on a lot of blocklists and mbedtls fingerprints get rejected.
///  2. **`VideoItem.httpHeaders` was dropped on the mpv path**, so every
///     authenticated URL (WebDAV Basic auth, a Jellyfin token) could never
///     play on this engine — even though Media3 received the same map.
///
/// ## The fix (layered, non-regressive)
///
///  * The direct open now sends the source's own headers + a browser-ish
///    `User-Agent` (so a link that works today keeps working).
///  * If the direct open still fails on an http(s) source, the URL is retried
///    **once per file** through a new OkHttp-backed loopback bridge that
///    reproduces Media3's exact network stack.
///
/// These tests pin the parts that are cheap to break silently: the header
/// mapping, the "direct open first / bridge only as fallback" ordering, the
/// channel contract on both sides, and the native bridge's range/status
/// mirroring (mpv's demuxer needs the origin's 206 + `Content-Range`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final player = File('lib/screens/player_screen.dart').readAsStringSync();
  final proxyDart =
      File('lib/services/http_stream_proxy.dart').readAsStringSync();
  final proxyKt = File(
          'android/app/src/main/kotlin/com/dreamplayer/app/HttpStreamProxy.kt')
      .readAsStringSync();
  final mainActivity = File(
          'android/app/src/main/kotlin/com/dreamplayer/app/MainActivity.kt')
      .readAsStringSync();

  group('mpv http header mapping', () {
    test('a source with no headers still gets a browser user-agent', () {
      final opts = buildMpvHttpHeaderOptions(const {});
      expect(opts.userAgent, mpvBrowserUserAgent);
      // Not the ffmpeg default — that is what CDNs refuse.
      expect(opts.userAgent, isNot(contains('Lavf')));
      expect(opts.referrer, isNull);
      expect(opts.headerFields, isNull);
      expect(opts.isEmpty, isTrue);
    });

    test('a source user-agent wins over the browser default', () {
      final opts = buildMpvHttpHeaderOptions(const {
        'User-Agent': 'MyPlayer/1.0',
      });
      expect(opts.userAgent, 'MyPlayer/1.0');
    });

    test('user-agent / referer are case-insensitive', () {
      final opts = buildMpvHttpHeaderOptions(const {
        'user-agent': 'UA/1',
        'REFERER': 'https://example.test/',
      });
      expect(opts.userAgent, 'UA/1');
      expect(opts.referrer, 'https://example.test/');
      // Both have dedicated mpv properties, so they must NOT also appear in
      // the generic list (that would send them twice).
      expect(opts.headerFields, isNull);
    });

    test('other headers become the comma-separated http-header-fields', () {
      final opts = buildMpvHttpHeaderOptions(const {
        'Authorization': 'Basic dXNlcjpwYXNz',
        'X-Api-Token': 'abc123',
      });
      expect(opts.headerFields,
          'Authorization: Basic dXNlcjpwYXNz,X-Api-Token: abc123');
    });

    test('commas inside a value are escaped (mpv splits on commas)', () {
      final opts = buildMpvHttpHeaderOptions(const {
        'Cookie': 'a=1, b=2',
      });
      expect(opts.headerFields, r'Cookie: a=1\, b=2');
    });

    test('backslashes are escaped before commas', () {
      final opts = buildMpvHttpHeaderOptions(const {
        'X-Thing': r'a\b,c',
      });
      expect(opts.headerFields, r'X-Thing: a\\b\,c');
    });

    test('blank names and values are dropped', () {
      final opts = buildMpvHttpHeaderOptions(const {
        '  ': 'value',
        'X-Empty': '   ',
        'X-Keep': 'ok',
      });
      expect(opts.headerFields, 'X-Keep: ok');
    });
  });

  group('mpv opens the direct URL first, the bridge only as fallback', () {
    test('_mpvOpen picks the bridge only when it serves THIS source', () {
      expect(player.contains('_mpvHttpBridgeSource == src'), isTrue);
    });

    test('the direct source is what mpv opens by default', () {
      // `playable` starts as the raw source and is only replaced by the
      // bridge URL inside the guarded branch above.
      expect(player.contains('var playable = src;'), isTrue);
    });

    test('the bridge retry is wired into the mpv error listener', () {
      expect(player.contains('_maybeMpvHttpBridgeRetry(msg)'), isTrue);
    });

    test('the retry happens BEFORE the error is surfaced', () {
      // Scope to the mpv error LISTENER — there is another
      // `_markMpvFailed('Fallback player error: …')` in the bridge-start
      // failure path, which is a different (correct) call site.
      final listenAt = player.indexOf('player.stream.error.listen(');
      expect(listenAt, greaterThan(-1));
      final retryAt = player.indexOf('_maybeMpvHttpBridgeRetry(msg)', listenAt);
      final failAt = player.indexOf(
          "_markMpvFailed('Fallback player error:", listenAt);
      expect(retryAt, greaterThan(listenAt));
      expect(failAt, greaterThan(listenAt));
      expect(retryAt, lessThan(failAt));
    });

    test('the retry happens once per file (a latch keyed by resume key)', () {
      expect(player.contains('_mpvHttpBridgeTriedKey == _resumeKey'), isTrue);
      expect(player.contains('_mpvHttpBridgeTriedKey = _resumeKey'), isTrue);
    });

    test('a fresh mpv session re-arms the retry and drops the old bridge', () {
      expect(player.contains('_mpvHttpBridgeTriedKey = null'), isTrue);
    });

    test('the bridge is torn down when the player is disposed', () {
      final disposeAt = player.indexOf('void dispose() {');
      final stopAt = player.indexOf('_stopMpvHttpBridge()', disposeAt);
      expect(disposeAt, greaterThan(-1));
      expect(stopAt, greaterThan(disposeAt));
    });

    test('the SMB loopback path is NOT affected by the http bridge', () {
      // `_stopMpvProxy` only stops the SMB token — the http bridge has its
      // own teardown, because the retry re-opens the file THROUGH the bridge
      // it just started (stopping it there would kill the retry).
      final stopProxyAt = player.indexOf('Future<void> _stopMpvProxy()');
      expect(stopProxyAt, greaterThan(-1));
      final stopProxyBody = player.substring(
          stopProxyAt, player.indexOf('Future<void> _stopMpvHttpBridge()'));
      expect(stopProxyBody, contains('SmbClient.instance.stopLoopback'));
      expect(stopProxyBody, isNot(contains('HttpStreamProxyClient')));
    });
  });

  group('mpv receives the source http headers', () {
    test('the headers are applied before the open', () {
      final applyAt = player.indexOf('_applyMpvHttpHeaders(player, video)');
      final openAt = player.indexOf('await player.open(');
      expect(applyAt, greaterThan(-1));
      expect(openAt, greaterThan(-1));
      expect(applyAt, lessThan(openAt));
    });

    test('VideoItem.httpHeaders are the source of the mpv properties', () {
      expect(player.contains('buildMpvHttpHeaderOptions(video.httpHeaders)'),
          isTrue);
    });

    test('user-agent / referrer / http-header-fields are all set', () {
      expect(player.contains("setProperty('user-agent'"), isTrue);
      expect(player.contains("setProperty('referrer'"), isTrue);
      expect(player.contains("setProperty('http-header-fields'"), isTrue);
    });
  });

  group('the http bridge channel contract', () {
    test('Dart and Kotlin agree on the channel name', () {
      expect(proxyDart.contains("MethodChannel('dreamplayer/httpproxy')"),
          isTrue);
      expect(proxyKt.contains('const val CHANNEL = "dreamplayer/httpproxy"'),
          isTrue);
    });

    test('Dart and Kotlin agree on the start/stop methods', () {
      expect(proxyDart.contains("invokeMethod<String>('start'"), isTrue);
      expect(proxyDart.contains("invokeMethod<void>('stop'"), isTrue);
      expect(proxyKt.contains('"start" ->'), isTrue);
      expect(proxyKt.contains('"stop" ->'), isTrue);
    });

    test('the bridge carries the url, the headers and the self-signed flag',
        () {
      expect(proxyDart.contains("'url': url"), isTrue);
      expect(proxyDart.contains("'headers': headers"), isTrue);
      expect(proxyDart.contains("'allowSelfSigned': allowSelfSigned"), isTrue);
    });

    test('MainActivity registers the channel', () {
      expect(mainActivity.contains('HttpStreamProxy.configure('), isTrue);
      expect(mainActivity.contains('HttpStreamProxy.CHANNEL'), isTrue);
    });
  });

  group('the native bridge behaves like the origin', () {
    test('it binds to loopback only', () {
      expect(proxyKt.contains('"127.0.0.1"'), isTrue);
      expect(proxyKt.contains('http://127.0.0.1:\$port/\$token'), isTrue);
    });

    test('it forwards the client Range upstream', () {
      // mpv seeks by issuing Range requests — the bridge must pass them on
      // so the origin answers 206 + Content-Range exactly like it does for
      // Media3.
      expect(proxyKt.contains('clientHeaders["range"]?.let'), isTrue);
      expect(proxyKt.contains('builder.header("Range", it)'), isTrue);
    });

    test('it mirrors the origin status and range headers', () {
      expect(proxyKt.contains('response.code'), isTrue);
      expect(proxyKt.contains('Content-Range'), isTrue);
      expect(proxyKt.contains('Accept-Ranges'), isTrue);
      expect(proxyKt.contains('Content-Length'), isTrue);
      expect(proxyKt.contains('Content-Type'), isTrue);
    });

    test('it streams the body instead of buffering it whole', () {
      expect(proxyKt.contains('streamBody('), isTrue);
      expect(proxyKt.contains('body.byteStream()'), isTrue);
    });

    test('it fetches with OkHttp — the same stack Media3 uses', () {
      expect(proxyKt.contains('okhttp3.OkHttpClient'), isTrue);
      expect(proxyKt.contains('client.newCall('), isTrue);
    });

    test('it supports GET and HEAD only', () {
      expect(proxyKt.contains('method != "GET" && method != "HEAD"'), isTrue);
    });
  });
}
