import 'package:flutter/services.dart';

const MethodChannel _upnpChannel = MethodChannel('dreamplayer/upnp');

class UpnpServer {
  const UpnpServer({
    required this.id,
    required this.name,
    required this.location,
    required this.controlUrl,
    required this.baseUrl,
  });

  final String id;
  final String name;
  final String location;
  final String controlUrl;
  final String baseUrl;

  factory UpnpServer.fromMap(Map<dynamic, dynamic> m) => UpnpServer(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? 'DLNA Server',
        location: m['location'] as String? ?? '',
        controlUrl: m['controlUrl'] as String? ?? '',
        baseUrl: m['baseUrl'] as String? ?? '',
      );
}

class UpnpEntry {
  const UpnpEntry({
    required this.name,
    required this.id,
    required this.isDirectory,
    this.url,
    this.size = 0,
    this.duration,
    this.transcoded = false,
    this.externalSubs = const [],
  });

  final String name;
  final String id;
  final bool isDirectory;
  final String? url;
  final int size;
  final String? duration;

  /// The server declared `DLNA.ORG_CI=1` — playing this URL triggers a
  /// server-side transcode (Jellyfin does it for items with external
  /// subtitles: lossy HEVC→H.264 TS, unseekable, HDR stripped).
  final bool transcoded;

  /// Subtitle resources the server advertised alongside the video
  /// (Jellyfin: one `<res>` per external subtitle DeliveryUrl).
  final List<UpnpExternalSub> externalSubs;

  factory UpnpEntry.fromMap(Map<dynamic, dynamic> m) => UpnpEntry(
        name: m['name'] as String? ?? '',
        id: m['id'] as String? ?? '',
        isDirectory: m['isDirectory'] == true,
        url: m['url'] as String?,
        size: m['size'] is num ? (m['size'] as num).toInt() : 0,
        duration: m['duration'] as String?,
        transcoded: m['transcoded'] == true,
        externalSubs: ((m['externalSubs'] as List?) ?? const [])
            .whereType<Map<dynamic, dynamic>>()
            .map(UpnpExternalSub.fromMap)
            .toList(),
      );

  bool get isVideo => !isDirectory && url != null && url!.isNotEmpty;
}

class UpnpExternalSub {
  const UpnpExternalSub({required this.url, required this.mimeType});

  final String url;
  final String mimeType;

  factory UpnpExternalSub.fromMap(Map<dynamic, dynamic> m) =>
      UpnpExternalSub(
        url: m['url'] as String? ?? '',
        mimeType: m['mime'] as String? ?? 'application/x-subrip',
      );

  /// File extension from the MIME type (srt / ass / vtt …), for labels.
  String get extension => switch (mimeType) {
        'text/x-ssa' || 'text/ass' => 'ass',
        'text/vtt' => 'vtt',
        _ => 'srt',
      };
}

class UpnpClient {
  UpnpClient._();
  static final UpnpClient instance = UpnpClient._();

  Future<List<UpnpServer>> discover() async {
    try {
      final raw = await _upnpChannel.invokeMethod<List<dynamic>>('discover');
      if (raw == null) return const [];
      return raw.map((e) => UpnpServer.fromMap(e as Map<dynamic, dynamic>)).toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      rethrow;
    }
  }

  Future<List<UpnpEntry>> browse(String serverId, String objectId) async {
    final raw = await _upnpChannel.invokeMethod<List<dynamic>>('browse', {
      'serverId': serverId,
      'objectId': objectId,
    });
    if (raw == null) return const [];
    return raw.map((e) => UpnpEntry.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  /// Invalidate the native listing cache for a server id (or all servers
  /// when [serverId] is null). The listing itself is cached for 60 s on
  /// the native side so re-visiting a folder is instant.
  Future<void> invalidateListingCache({String? serverId}) async {
    await _upnpChannel.invokeMethod<void>('invalidateListingCache', {
      'serverId': ?serverId,
    });
  }

  /// Last discovery diagnostics from the native side (iOS only; null when
  /// unsupported). Shown in the empty state so on-device failures are
  /// visible without a Mac console.
  Future<List<String>?> diagnostics() async {
    try {
      final raw = await _upnpChannel.invokeMethod<List<dynamic>>('getDiagnostics');
      return raw?.map((e) => e.toString()).toList();
    } catch (_) {
      return null;
    }
  }
}
