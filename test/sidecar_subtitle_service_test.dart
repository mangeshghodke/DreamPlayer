import 'dart:io' show Platform;

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/sidecar_subtitle_service.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:flutter_test/flutter_test.dart';

VideoExternalSub _sub(String uri, {bool isDefault = false, String label = 't'}) =>
    VideoExternalSub(uri: uri, label: label, isDefault: isDefault);

/// Tests for the sidecar subtitle discovery helper. The full SMB/WebDAV/FTP
/// network paths are exercised on-device; here we cover the URI parsing +
/// filename pairing rules in isolation, so the same code path stays safe
/// on a CI box that has no NAS.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SidecarSubtitleService.find', () {
    test('returns empty for empty uri', () async {
      final video = VideoItem(
        id: 'x', title: 'x', duration: Duration.zero,
      );
      final result = await SidecarSubtitleService.instance.find(video);
      expect(result, isEmpty);
    });

    test('returns empty on iOS regardless of source (v1 limitation)', () async {
      // The Android-only gate ensures iOS never calls into the native SMB
      // channels (which would just fail there). Local files already have
      // their own sibling auto-pairing on iOS.
      if (Platform.isAndroid) {
        return; // Not applicable; on Android the SMB path runs.
      }
      final video = VideoItem(
        id: 'x', title: 'x', duration: Duration.zero,
        uri: 'smb://srv/share/Show.S01E01.mkv',
      );
      final result = await SidecarSubtitleService.instance.find(video);
      expect(result, isEmpty);
    });

    test('never probes URL-siblings for a generic http stream URL (Jellyfin '
        "'Open in external player' regression)", () async {
      // A Jellyfin direct-play / stream URL handed to the app via "Open in
      // external player" has no WebDAV server identity. Before, `find` treated
      // it as a generic http(s) source and issued blocking sibling-subtitle
      // GET probes against the Jellyfin server *before* playback started,
      // hanging the player ("does not work at all"). This must resolve to
      // empty without any network — just an empty webdavServerId.
      final video = VideoItem(
        id: 'x',
        title: 'x',
        duration: Duration.zero,
        uri: 'http://192.168.1.16:8096/Videos/123/api-stream?static=true&ApiKey=k',
      );
      final result = await SidecarSubtitleService.instance.find(video);
      expect(result, isEmpty);
    });
  });

  group('promoteFirstExternalAsDefault', () {
    test('empty list returns empty', () {
      expect(promoteFirstExternalAsDefault(const []), isEmpty);
    });

    test('promotes first when none is default', () {
      final promoted = promoteFirstExternalAsDefault([
        _sub('a'),
        _sub('b'),
        _sub('c'),
      ]);
      expect(promoted[0].isDefault, isTrue);
      expect(promoted[1].isDefault, isFalse);
      expect(promoted[2].isDefault, isFalse);
    });

    test('preserves server-flagged default', () {
      // Even if "a" is listed first, "b" is already default — don't touch.
      final subs = [
        _sub('a'),
        _sub('b', isDefault: true),
        _sub('c'),
      ];
      final promoted = promoteFirstExternalAsDefault(subs);
      expect(promoted[0].isDefault, isFalse);
      expect(promoted[1].isDefault, isTrue);
      expect(promoted[2].isDefault, isFalse);
    });

    test('preserves URIs + labels (does not rebuild the first track)', () {
      final promoted = promoteFirstExternalAsDefault([
        _sub('https://srv/Movies/Show.S01E01.eng.srt', label: 'eng'),
        _sub('https://srv/Movies/Show.S01E01.jpn.srt', label: 'jpn'),
      ]);
      expect(promoted[0].uri, 'https://srv/Movies/Show.S01E01.eng.srt');
      expect(promoted[0].label, 'eng');
      expect(promoted[0].isDefault, isTrue);
    });
  });

  group('urlBasePath', () {
    test('empty when URL has no path', () {
      expect(SidecarSubtitleService.urlBasePath('http://192.168.1.16:8080'),
          isEmpty);
    });

    test('returns a single mount segment', () {
      expect(SidecarSubtitleService.urlBasePath('http://192.168.1.16:8080/dav'),
          '/dav');
    });

    test('returns a multi-segment base path', () {
      expect(
          SidecarSubtitleService.urlBasePath('https://nas/dav/root'),
          '/dav/root');
    });

    test('strips a trailing slash', () {
      expect(
          SidecarSubtitleService.urlBasePath('http://host:8080/dav/'),
          '/dav');
    });
  });

  group('relativeToBasePath', () {
    test('empty base returns urlPath unchanged', () {
      expect(SidecarSubtitleService.relativeToBasePath('', 'Movies/TestSub/a.mp4'),
          'Movies/TestSub/a.mp4');
    });

    test('strips a /dav mount prefix (leading-slash normalization)', () {
      // urlBasePath yields `/dav`, _parseHttpUri yields `dav/Movies/...` —
      // the ordering bug that hid all WebDAV sidecars on a /dav-mounted server.
      expect(
          SidecarSubtitleService.relativeToBasePath('/dav',
              'dav/Movies/TestSub/Test Video.en.mp4'),
          'Movies/TestSub/Test Video.en.mp4');
    });

    test('urlPath exactly equal to base returns empty', () {
      expect(SidecarSubtitleService.relativeToBasePath('/dav', 'dav'), isEmpty);
    });

    test('unrelated base leaves urlPath untouched', () {
      expect(
          SidecarSubtitleService.relativeToBasePath('/other',
              'dav/Movies/TestSub/a.mp4'),
          'dav/Movies/TestSub/a.mp4');
    });

    test('no base path match (server URL bare, file deep) is a no-op', () {
      expect(
          SidecarSubtitleService.relativeToBasePath('', 'Movies/a.mp4'),
          'Movies/a.mp4');
    });
  });

  group('buildSubs pairing (path form must match)', () {
    final decodedVideo = 'Movies/TestSub/Test Video.en.mp4';
    final decodedSidecar = 'Movies/TestSub/Test Video.en.srt';

    test('decoded video path pairs with decoded sidecar', () {
      // This is what `_findWebDavOrHttp` now produces after the
      // `Uri.decodeComponent` fix — the two MOST match.
      final subs = SidecarSubtitleService.instance.buildSubs(
        source: [(decodedSidecar.split('/').last, decodedSidecar)],
        videoPath: decodedVideo,
        buildFullUri: (p) => 'http://192.168.1.16:8080/dav/$p',
      );
      expect(subs, hasLength(1));
      expect(subs.first.isDefault, isTrue);
      expect(subs.first.label, 'Test Video.en');
    });

    test('percent-encoded video path does NOT pair (the %20 bug)', () {
      // Regression guard: if the videoPath were still `Test%20Video.en.mp4`
      // it must never pair with the decoded `Test Video.en.srt`.
      final subs = SidecarSubtitleService.instance.buildSubs(
        source: [(decodedSidecar.split('/').last, decodedSidecar)],
        videoPath: 'Movies/TestSub/Test%20Video.en.mp4',
        buildFullUri: (p) => 'http://192.168.1.16:8080/dav/$p',
      );
      expect(subs, isEmpty);
    });
  });

  group('candidateSiblingUrls (Nova-style direct probes)', () {
    test('empty for unparseable URI', () {
      expect(SidecarSubtitleService.candidateSiblingUrls(''), isEmpty);
    });

    test('empty for URL with no path', () {
      expect(
          SidecarSubtitleService.candidateSiblingUrls('http://192.168.1.16:8080'),
          isEmpty);
    });

    test('first candidate is the same-name .srt, properly encoded', () {
      // Encoded input (as the WebDAV screen builds it) must produce a SINGLE-encoded
      // candidate (`Test%20Video.en.srt`, NOT `Test%2520...`). Regression guard
      // for the double-encoding bug that would miss every space-named file.
      final candidates = SidecarSubtitleService.candidateSiblingUrls(
        'http://192.168.1.16:8080/dav/Movies/TestSub/Test%20Video.en.mp4',
      );
      expect(candidates, isNotEmpty);
      final (firstUrl, firstName) = candidates.first;
      expect(firstName, 'Test Video.en.srt');
      expect(firstUrl,
          'http://192.168.1.16:8080/dav/Movies/TestSub/Test%20Video.en.srt');
      expect(firstUrl.contains('%2520'), isFalse, reason: 'must not double-encode');
    });

    test('decoded input also yields a valid single-encoded URL', () {
      final candidates = SidecarSubtitleService.candidateSiblingUrls(
        'http://host/dav/Movies/Test Video.en.mp4',
      );
      final (firstUrl, _) = candidates.first;
      expect(firstUrl, 'http://host/dav/Movies/Test%20Video.en.srt');
    });

    test('covers every supported extension; srt first', () {
      final urls = SidecarSubtitleService.candidateSiblingUrls(
        'http://host/Movies/Show.S01E01.mkv',
      );
      expect(urls.first.$1.endsWith('.srt'), isTrue);
      expect(
        urls.every((e) => e.$1.startsWith('http://host/Movies/Show.S01E01.')),
        isTrue,
      );
    });

    test('video at server root builds a root-level candidate', () {
      final candidates = SidecarSubtitleService.candidateSiblingUrls(
        'http://host/file.mp4',
      );
      expect(candidates.first.$1, 'http://host/file.srt');
    });
  });

  group('SidecarSubtitleService.ensureLocal', () {
    test('passes through already-local file:// and unknown schemes', () async {
      final video = VideoItem(id: 'x', title: 'x', duration: Duration.zero);
      final local = _sub('file:///cache/show.srt', isDefault: true);
      final exotic = _sub('webvtt:magnet://nope/show.vtt');
      final out = await SidecarSubtitleService.instance
          .ensureLocal(video, [local, exotic]);
      expect(out[0].uri, 'file:///cache/show.srt');
      expect(out[0].isDefault, isTrue);
      expect(out[1].uri, 'webvtt:magnet://nope/show.vtt');
    });

    test('remote fetch failure degrades to original URI (never drops track)',
        () async {
      // In a headless test the SMB/FTP/WebDAV MethodChannels are absent, so
      // the native fetch throws (caught) → the original remote URI is kept so
      // the engine can still stream it. This is the "never drop a sidecar"
      // contract behind the Nova-style local-copy prefetch.
      final video = VideoItem(id: 'x', title: 'x', duration: Duration.zero);
      final smb = _sub('smb://server/share/Show.eng.srt', isDefault: true);
      final out =
          await SidecarSubtitleService.instance.ensureLocal(video, [smb]);
      expect(out.single.uri, 'smb://server/share/Show.eng.srt');
      expect(out.single.isDefault, isTrue);
    });

    test('Jellyfin subtitle GET timeout keeps the remote track (the '
        "'webdav, timed out connecting to the server' regression)", () async {
      // Regression: a Jellyfin video with external subs localizes each
      // subtitle via the WebDAV fetchUrl channel. When the Jellyfin server is
      // slow/unreachable the native side used to report a
      // PlatformException('webdav', 'Timed out connecting to the server.'),
      // which propagated out of ensureLocal and aborted the whole video open.
      // It must stay best-effort: keep the remote URI and let playback
      // proceed (the engine streams the subtitle itself if needed).
      const channel = MethodChannel('dreamplayer/webdav');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        throw PlatformException(
          code: 'webdav',
          message: 'Timed out connecting to the server.',
        );
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      final video = VideoItem(
        id: 'j1',
        title: 'Show',
        duration: Duration.zero,
        uri: 'http://192.168.1.16:8096/Videos/abc/stream?static=true&ApiKey=k',
        httpHeaders: const {'X-Emby-Token': 'abc'},
      );
      const sub = VideoExternalSub(
        uri: 'http://192.168.1.16:8096/Videos/abc/Subtitles/0/0/Stream.srt'
            '?static=true&ApiKey=k',
        label: 'Show.S01E01.eng.srt',
        language: 'eng',
      );
      final out = await SidecarSubtitleService.instance
          .ensureLocal(video, const [sub]);
      expect(calls, ['fetchUrl']);
      expect(out.single.uri, sub.uri); // remote URI kept → playback not aborted
      expect(out.single.label, 'Show.S01E01.eng.srt');
    });
  });
}
