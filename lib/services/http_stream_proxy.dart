import 'package:flutter/services.dart';

/// A local HTTP bridge for the **libmpv** engine.
///
/// ## Why it exists
///
/// The two engines use different HTTP stacks:
///
///  * Media3 → OkHttp (Conscrypt TLS, `User-Agent: okhttp/4.x`).
///  * libmpv → ffmpeg's own http protocol (bundled mbedtls,
///    `User-Agent: Lavf/63.1.100`).
///
/// CDNs in front of private trackers routinely refuse one of the two — the
/// reported case was a Cloudflare-fronted host with a client-bound
/// `?selection=` token that libmpv could not open while Media3 played it
/// fine. `HttpStreamProxy` (Android) fetches the URL with **the same OkHttp
/// client the Media3 engine uses** and serves it to mpv over
/// `http://127.0.0.1:<port>/<token>`, so the mpv engine sees a source the
/// origin has already accepted.
///
/// The bridge is only used as a **fallback**: the player opens the direct URL
/// first (so a link that works today keeps working exactly as it does) and
/// retries through the bridge only when the direct open fails.
class HttpStreamProxyClient {
  HttpStreamProxyClient._();

  static final HttpStreamProxyClient instance = HttpStreamProxyClient._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/httpproxy');

  /// Starts serving [url] and returns the loopback URL, or null when the
  /// bridge could not be started (the caller then keeps the direct URL).
  Future<String?> start({
    required String url,
    Map<String, String> headers = const {},
    bool allowSelfSigned = false,
  }) async {
    try {
      final bridged = await _channel.invokeMethod<String>('start', {
        'url': url,
        'headers': headers,
        'allowSelfSigned': allowSelfSigned,
      });
      if (bridged == null || bridged.isEmpty) return null;
      return bridged;
    } on MissingPluginException {
      // Not Android (or an older build) — the caller keeps the direct URL.
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Tears down the bridge previously returned by [start].
  Future<void> stop(String token) async {
    if (token.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('stop', {'token': token});
    } catch (_) {
      // The bridge is best-effort; a failed teardown must never break playback.
    }
  }
}
