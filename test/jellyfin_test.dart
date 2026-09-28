import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/jellyfin_client.dart';
import 'package:dream_player/services/opensubtitles_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  group('PlaybackSource.jellyfin', () {
    test('resume key with jellyfin prefix maps to jellyfin source', () {
      const video = VideoItem(
        id: 'j1',
        title: 'Movie',
        uri: 'http://192.168.1.16:8096/Videos/abc/stream?ApiKey=x',
        resumeKey: 'jellyfin:192.168.1.16/abc',
        duration: Duration.zero,
      );
      expect(video.playbackSource, PlaybackSource.jellyfin);
      expect(PlaybackSource.jellyfin.label, 'Jellyfin');
    });

    test('network uri without jellyfin key stays network', () {
      const video = VideoItem(
        id: 'n1',
        title: 'Movie',
        uri: 'http://192.168.1.16:8096/Videos/abc/stream',
        duration: Duration.zero,
      );
      expect(video.playbackSource, PlaybackSource.network);
    });
  });

  group('JellyfinServer', () {
    test('toJson/fromJson round-trips persisted fields', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        username: 'admin',
        token: 'tok123',
        userId: 'u1',
        allowSelfSigned: true,
      );
      final restored = JellyfinServer.fromJson(server.toJson());
      expect(restored.name, 'Home');
      expect(restored.url, 'http://192.168.1.16:8096');
      expect(restored.username, 'admin');
      expect(restored.token, 'tok123');
      expect(restored.userId, 'u1');
      expect(restored.allowSelfSigned, true);
      expect(restored.isAuthenticated, true);
    });

    test('copyWith clears auth when token dropped', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        token: 'tok',
        userId: 'u1',
      );
      final expired = server.copyWith(token: null, userId: null);
      expect(expired.isAuthenticated, false);
    });
  });

  group('JellyfinClient URL helpers', () {
    test('normalizeUrl adds scheme and strips trailing slash', () {
      expect(JellyfinClient.normalizeUrl('192.168.1.16:8096'),
          'http://192.168.1.16:8096');
      expect(JellyfinClient.normalizeUrl('https://host:8920/'),
          'https://host:8920');
    });

    test('streamUrl embeds static + mediaSourceId + ApiKey', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        token: 'tok123',
        userId: 'u1',
      );
      const item = JellyfinItem(
        id: 'item1',
        name: 'Movie',
        mediaType: 'Video',
        mediaSourceId: 'source1',
      );
      final url = JellyfinClient().streamUrl(server, item);
      expect(url, contains('/Videos/item1/stream'));
      expect(url, contains('static=true'));
      expect(url, contains('mediaSourceId=source1'));
      expect(url, contains('ApiKey=tok123'));
    });

    test('resumeKey is host/item and stable across tokens', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        token: 'tok123',
        userId: 'u1',
      );
      const item = JellyfinItem(id: 'item1', name: 'Movie');
      expect(JellyfinClient().resumeKey(server, item), 'jellyfin:192.168.1.16/item1');
    });
  });

  group('JellyfinItem parsing', () {
    test('fromJson extracts MediaSources id and fields', () {
      final item = JellyfinItem.fromJson({
        'Id': 'abc',
        'Name': 'Show S01E01',
        'IsFolder': false,
        'Type': 'Episode',
        'MediaType': 'Video',
        'RunTimeTicks': 4200000000,
        'Width': 1920,
        'Height': 1080,
        'MediaSources': [
          {'Id': 'src1', 'Size': 4509715660},
        ],
      });
      expect(item.isPlayable, true);
      expect(item.mediaSourceId, 'src1');
      expect(item.duration, const Duration(seconds: 420));
      expect(item.resolution, '1920x1080');
      expect(item.sizeBytes, 4509715660);
      expect(item.sizeLabel, '4.2 GB');
    });

    test('fromJson falls back to top-level Size when MediaSources lacks it', () {
      final item = JellyfinItem.fromJson({
        'Id': 'abc',
        'Name': 'Show S01E01',
        'IsFolder': false,
        'Type': 'Episode',
        'MediaType': 'Video',
        'Size': 1048576,
        'MediaSources': [
          {'Id': 'src1'},
        ],
      });
      expect(item.sizeBytes, 1048576);
      expect(item.sizeLabel, '1.0 MB');
    });

    test('fromJson extracts IndexNumber/ParentIndexNumber for seasonLabel', () {
      final item = JellyfinItem.fromJson({
        'Id': 'e4',
        'Name': 'Chapter Four',
        'IsFolder': false,
        'Type': 'Episode',
        'MediaType': 'Video',
        'IndexNumber': 4,
        'ParentIndexNumber': 1,
      });
      expect(item.isPlayable, true);
      expect(item.indexNumber, 4);
      expect(item.parentIndexNumber, 1);
      expect(item.seasonLabel, 'S01E04');
    });

    test('seasonLabel is empty when numbers missing', () {
      const item = JellyfinItem(id: 'm1', name: 'Movie', mediaType: 'Video');
      expect(item.seasonLabel, '');
    });

    test('videoItem builds a playable VideoItem from the server + item', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        token: 'tok123',
        userId: 'u1',
      );
      const item = JellyfinItem(
        id: 'item1',
        name: 'Show S01E01',
        mediaType: 'Video',
        runTimeTicks: 4200000000,
      );
      final video = JellyfinClient().videoItem(server, item);
      expect(video.title, 'Show S01E01');
      expect(video.uri, JellyfinClient().streamUrl(server, item));
      expect(video.resumeKey, 'jellyfin:192.168.1.16/item1');
      expect(video.jellyfinServerId, '192.168.1.16');
      expect(video.jellyfinItemId, 'item1');
      expect(video.duration, const Duration(seconds: 420));
      expect(video.playbackSource, PlaybackSource.jellyfin);
    });

    test('folder items are not playable', () {
      final item = JellyfinItem.fromJson({
        'Id': 'lib',
        'Name': 'Movies',
        'IsFolder': true,
        'Type': 'CollectionFolder',
      });
      expect(item.isFolder, true);
      expect(item.isPlayable, false);
    });
  });

  group('JellyfinItemInfo', () {
    test('fromApi builds info with server image URLs', () {
      final info = JellyfinItemInfo.fromApi({
        'Id': 'ser1',
        'Name': 'Succession',
        'Type': 'Series',
        'Overview': 'A family drama.',
        'ProductionYear': 2018,
        'Genres': ['Drama'],
        'CommunityRating': 8.3,
        'RunTimeTicks': 36000000000,
        'ImageTags': {'Primary': 'p1'},
        'BackdropImageTags': ['b1'],
      }, serverUrl: 'http://192.168.1.16:8096', token: 'tok');
      expect(info.id, 'ser1');
      expect(info.name, 'Succession');
      expect(info.isTv, true);
      expect(info.kindLabel, 'TV Series');
      expect(info.year, 2018);
      expect(info.genres, ['Drama']);
      expect(info.communityRating, 8.3);
      expect(info.duration, const Duration(hours: 1));
      expect(info.durationLabel, '1:00h');
      expect(
        info.imageUrl,
        contains('/Items/ser1/Images/Primary?tag=p1&ApiKey=tok'),
      );
      expect(
        info.backdropUrl,
        contains('/Items/ser1/Images/Backdrop?tag=b1&ApiKey=tok'),
      );
    });

    test('fromApi handles missing artwork and movie type', () {
      final info = JellyfinItemInfo.fromApi({
        'Id': 'm1',
        'Name': 'Dune',
        'Type': 'Movie',
      }, serverUrl: 'http://x', token: 't');
      expect(info.imageUrl, isNull);
      expect(info.backdropUrl, isNull);
      expect(info.isMovie, true);
      expect(info.isTv, false);
      expect(info.kindLabel, 'Movie');
      expect(info.durationLabel, '');
    });

    test('toJson/fromJson round-trips cache fields', () {
      final info = JellyfinItemInfo.fromApi({
        'Id': 'ser1',
        'Name': 'Succession',
        'Type': 'Series',
        'Overview': 'A family drama.',
        'ProductionYear': 2018,
        'Genres': ['Drama'],
        'CommunityRating': 8.3,
        'RunTimeTicks': 36000000000,
        'ImageTags': {'Primary': 'p1'},
        'BackdropImageTags': ['b1'],
      }, serverUrl: 'http://192.168.1.16:8096', token: 'tok');
      final restored = JellyfinItemInfo.fromJson(info.toJson());
      expect(restored.id, info.id);
      expect(restored.name, info.name);
      expect(restored.type, info.type);
      expect(restored.overview, info.overview);
      expect(restored.year, info.year);
      expect(restored.genres, info.genres);
      expect(restored.communityRating, info.communityRating);
      expect(restored.runTimeTicks, info.runTimeTicks);
      expect(restored.imageUrl, info.imageUrl);
      expect(restored.backdropUrl, info.backdropUrl);
    });
  });

  group('resolvePosterItemId', () {
    const seasonAncestors = [
      {'Id': 'ser1', 'Type': 'Series'},
      {'Id': 'lib1', 'Type': 'CollectionFolder'},
    ];
    const folderAncestors = [
      {'Id': 'lib1', 'Type': 'CollectionFolder'},
    ];

    test('series item keeps itself', () {
      expect(
        JellyfinClient.resolvePosterItemId(
          'Series',
          'ser1',
          seasonAncestors,
        ),
        'ser1',
      );
    });

    test('movie item keeps itself', () {
      expect(
        JellyfinClient.resolvePosterItemId('Movie', 'm1', const []),
        'm1',
      );
    });

    test('season resolves to its series ancestor', () {
      expect(
        JellyfinClient.resolvePosterItemId(
          'Season',
          'sea1',
          seasonAncestors,
        ),
        'ser1',
      );
    });

    test('episode resolves to the nearest series ancestor', () {
      expect(
        JellyfinClient.resolvePosterItemId('Episode', 'e1', const [
          {'Id': 'sea1', 'Type': 'Season'},
          {'Id': 'ser1', 'Type': 'Series'},
          {'Id': 'lib1', 'Type': 'CollectionFolder'},
        ]),
        'ser1',
      );
    });

    test('plain folder without a series ancestor keeps itself', () {
      expect(
        JellyfinClient.resolvePosterItemId(
          'Folder',
          'f1',
          folderAncestors,
        ),
        isNull,
      );
    });
  });

  group('Jellyfin folder-meta cache', () {
    const folderId = 'jellyfin_folder_192.168.1.16_ser1';
    final info = JellyfinItemInfo(
      id: 'ser1',
      name: 'Succession',
      type: 'Series',
      year: 2018,
      genres: const ['Drama'],
    );

    test('saveFolderMeta + loadAllFolderMeta round-trip', () async {
      final client = JellyfinClient();
      await client.saveFolderMeta(folderId, info);
      final all = await client.loadAllFolderMeta();
      expect(all.length, 1);
      expect(all[folderId]!.name, 'Succession');
      expect(all[folderId]!.year, 2018);
    });

    test('removeFolderMeta deletes the entry', () async {
      final client = JellyfinClient();
      await client.saveFolderMeta(folderId, info);
      await client.saveFolderMeta('other', info);
      await client.removeFolderMeta(folderId);
      final all = await client.loadAllFolderMeta();
      expect(all.keys, ['other']);
    });

    test('loadAllFolderMeta returns empty for corrupt json', () async {
      SharedPreferences.setMockInitialValues(
        {'dreamplayer.jellyfinFolderMeta': 'not json'},
      );
      expect(await JellyfinClient().loadAllFolderMeta(), isEmpty);
    });
  });

  group('transcode fallback', () {
    const server = JellyfinServer(
      name: 'Home',
      url: 'http://192.168.1.16:8096',
      username: 'me',
      token: 'tok123',
      userId: 'u1',
    );

    final item = JellyfinItem(
      id: 'vid42',
      name: 'Oldboy',
      mediaType: 'Video',
      mediaSourceId: 'msrc9',
    );

    test('transcodeUrl builds an HLS master playlist request', () {
      final url = JellyfinClient().transcodeUrl(server, item, devId: 'dev1');
      expect(url, contains('/Videos/vid42/master.m3u8'));
      expect(url, contains('MediaSourceId=msrc9'));
      expect(url, contains('DeviceId=dev1'));
      expect(url, contains('VideoCodec=h264'));
      expect(url, contains('AudioCodec=aac'));
      expect(url, contains('ApiKey=tok123'));
      expect(
        url,
        contains(
          'MaxStreamingBitrate=${JellyfinClient.defaultTranscodeBitrateBps}',
        ),
      );
    });

    test('transcodeUrl honors a custom bitrate cap', () {
      const low = 4000000;
      final url =
          JellyfinClient().transcodeUrl(server, item, devId: 'd', maxBitrateBps: low);
      expect(url, contains('MaxStreamingBitrate=$low'));
    });

    test('isTranscodeUri detects m3u8 and ignores direct streams', () {
      expect(
        JellyfinClient.isTranscodeUri(
          'http://s:8096/Videos/a/master.m3u8?DeviceId=x',
        ),
        isTrue,
      );
      expect(
        JellyfinClient.isTranscodeUri(
          'http://s:8096/Videos/a/stream?static=true',
        ),
        isFalse,
      );
      expect(JellyfinClient.isTranscodeUri(null), isFalse);
    });

    test('transcodeFallbackFor returns null for non-Jellyfin videos', () async {
      const video = VideoItem(
        id: 'f1',
        title: 'Local file',
        duration: Duration.zero,
      );
      expect(await JellyfinClient().transcodeFallbackFor(video), isNull);
    });

    test('transcodeFallbackFor swaps the URI for HLS and keeps identity',
        () async {
      SharedPreferences.setMockInitialValues({
        'dreamplayer.jellyfinServers':
            '[{"name":"Home","url":"http://192.168.1.16:8096","username":"me","token":"tok123","userId":"u1","allowSelfSigned":true}]',
      });
      const video = VideoItem(
        id: 'jf1',
        title: 'Oldboy',
        uri:
            'http://192.168.1.16:8096/Videos/vid42/stream?static=true&mediaSourceId=msrc9&ApiKey=tok123',
        resumeKey: 'jellyfin:192.168.1.16/vid42',
        duration: Duration(minutes: 97),
        jellyfinServerId: '192.168.1.16',
        jellyfinItemId: 'vid42',
      );
      final fb = await JellyfinClient().transcodeFallbackFor(video);
      expect(fb, isNotNull);
      expect(fb!.uri, contains('/Videos/vid42/master.m3u8'));
      expect(fb.uri, contains('ApiKey=tok123'));
      expect(fb.resumeKey, video.resumeKey);
      expect(fb.jellyfinItemId, video.jellyfinItemId);
      expect(fb.allowSelfSigned, isTrue);
      expect(JellyfinClient.isTranscodeUri(fb.uri), isTrue);
    });

    test('transcodeFallbackFor returns null when server is unknown or '
        'unauthenticated', () async {
      const video = VideoItem(
        id: 'jf2',
        title: 'Movie',
        resumeKey: 'jellyfin:10.0.0.99/x1',
        duration: Duration.zero,
        jellyfinServerId: '10.0.0.99',
        jellyfinItemId: 'x1',
      );
      // No saved servers at all.
      expect(await JellyfinClient().transcodeFallbackFor(video), isNull);
      // Saved but no token (never signed in).
      SharedPreferences.setMockInitialValues({
        'dreamplayer.jellyfinServers':
            '[{"name":"Far","url":"http://10.0.0.99:8096","username":"me"}]',
      });
      expect(await JellyfinClient().transcodeFallbackFor(video), isNull);
    });

    test('deviceId persists across client instances', () async {
      final first = await JellyfinClient().deviceId;
      expect(first, isNotEmpty);
      final second = await JellyfinClient().deviceId;
      expect(second, first);
    });
  });

  group('JellyfinClient.itemIdFromStreamUrl (Open in external player)', () {
    test('modern /Videos/{id}/stream shape', () {
      expect(
        JellyfinClient.itemIdFromStreamUrl(
          'http://192.168.1.16:8096/Videos/0123456789abcdef0123456789abcdef/'
          'stream?static=true&mediaSourceId=ab&ApiKey=xyz',
        ),
        '0123456789abcdef0123456789abcdef',
      );
    });

    test('/Videos/{id}/{sourceId}/stream shape', () {
      expect(
        JellyfinClient.itemIdFromStreamUrl(
          'https://nas:8920/Videos/uuid1/uuid2/stream?static=true&ApiKey=t',
        ),
        'uuid1',
      );
    });

    test('short ids (some Jellyfin installs) also match', () {
      expect(
        JellyfinClient.itemIdFromStreamUrl(
          'http://10.0.0.5:8096/Videos/xyz123/stream?static=true',
        ),
        'xyz123',
      );
    });

    test('non-video paths / audio return null', () {
      expect(
        JellyfinClient.itemIdFromStreamUrl('http://h:8096/Audio/abc/stream'),
        isNull,
      );
      expect(
        JellyfinClient.itemIdFromStreamUrl('http://h:8096/Items/abc'),
        isNull,
      );
      expect(JellyfinClient.itemIdFromStreamUrl(''), isNull);
    });

    test('cx / webdav URLs return null', () {
      expect(
        JellyfinClient.itemIdFromStreamUrl('http://127.0.0.1:8888/SMB/x/y.mkv'),
        isNull,
      );
      expect(
        JellyfinClient.itemIdFromStreamUrl('http://u:p@h:80/dav/the.video.mkv'),
        isNull,
      );
    });
  });

  group('meaningfulSubtitleFileName (real subtitle names)', () {
    test('real names pass through untouched', () {
      expect(
        meaningfulSubtitleFileName(
          apiFileName: 'Avatar.2009.eng.srt',
          language: 'en',
          videoTitle: 'Avatar',
        ),
        'Avatar.2009.eng.srt',
      );
    });

    test('numeric upload id is replaced by the video title + language', () {
      final n = meaningfulSubtitleFileName(
        apiFileName: '1324.srt',
        language: 'en',
        videoTitle: 'Avatar',
      );
      expect(n, 'Avatar.en.srt');
      expect(n.contains('1324'), isFalse);
    });

    test('generic boilerplate names are replaced too', () {
      expect(
        meaningfulSubtitleFileName(
          apiFileName: 'subtitle.srt',
          language: 'pob',
          videoTitle: 'House S02 E04',
        ),
        'House_S02_E04.pob.srt',
      );
    });

    test('empty api name falls back to title + srt', () {
      expect(
        meaningfulSubtitleFileName(
          apiFileName: '',
          language: 'en',
          videoTitle: 'Dune Part Two',
        ),
        'Dune_Part_Two.en.srt',
      );
    });

    test('non-srt subtitle extensions are preserved', () {
      expect(
        meaningfulSubtitleFileName(
          apiFileName: '42.ass',
          language: 'eng',
          videoTitle: 'Oldboy',
        ),
        'Oldboy.eng.ass',
      );
    });

    test('unknown extensions degrade to srt', () {
      expect(
        meaningfulSubtitleFileName(
          apiFileName: '7.bin',
          language: 'en',
          videoTitle: 'Her (2013)',
        ),
        'Her_2013.en.srt',
      );
    });

    test('video title language tag is not duplicated', () {
      expect(
        meaningfulSubtitleFileName(
          apiFileName: '99.srt',
          language: 'en',
          videoTitle: 'Avatar.en',
        ),
        'Avatar.en.srt',
      );
    });
  });

  group('subtitleFileNameLabel', () {
    test('strips the last extension only', () {
      expect(subtitleFileNameLabel('Star_Wars.eng.srt'), 'Star_Wars.eng');
      expect(subtitleFileNameLabel('Movie.ass'), 'Movie');
      expect(subtitleFileNameLabel('noext'), 'noext');
    });
  });

  group('JellyfinExternalSub.displayTitle (exact subtitle name)', () {
    JellyfinExternalSub withJson(Map<String, Object?> stream) =>
        JellyfinExternalSub.fromJson(stream);

    test('Title (the file name) wins', () {
      expect(
        withJson({
          'Index': 0,
          'Codec': 'srt',
          'Title': 'Show.S01E01.eng.srt',
          'Language': 'eng',
          'DeliveryUrl': '/Videos/x/y/Subtitles/0/0/Stream.srt',
        }).displayTitle,
        'Show.S01E01.eng.srt',
      );
    });

    test('basename of Path is used when Title is missing', () {
      expect(
        withJson({
          'Index': 0,
          'Codec': 'srt',
          'Language': 'eng',
          'Path': '/media/TV/Show S01E01/Show.S01E01.eng.srt',
          'DeliveryUrl': '/Videos/x/y/Subtitles/0/0/Stream.srt',
        }).displayTitle,
        'Show.S01E01.eng.srt',
      );
    });

    test('Windows-style Path backslashes are resolved too', () {
      expect(
        withJson({
          'Index': 0,
          'Codec': 'ass',
          'Language': 'zho',
          'Path': r'D:\Media\Series\Show.S01E01.chs.ass',
          'DeliveryUrl': '/Videos/x/y/Subtitles/0/0/Stream.ass',
        }).displayTitle,
        'Show.S01E01.chs.ass',
      );
    });

    test('full language name when no file name exists', () {
      expect(
        withJson({
          'Index': 2,
          'Codec': 'srt',
          'Language': 'eng',
          'DeliveryUrl': '/Videos/x/y/Subtitles/2/0/Stream.srt',
        }).displayTitle,
        'English',
      );
    });

    test('neutral fallback never yields "undefined"', () {
      expect(
        withJson({
          'Index': 3,
          'Codec': 'srt',
          'Language': 'und',
          'DeliveryUrl': '/Videos/x/y/Subtitles/3/0/Stream.srt',
        }).displayTitle,
        'External subtitle 4',
      );
    });

    test('fromJson keeps Title and DisplayTitle separate from Path', () {
      final parsed = withJson({
        'Index': 1,
        'Codec': 'srt',
        'Title': 'My.Custom.Name.srt',
        'Language': 'eng',
        'Path': '/media/movies/My.Custom.Name.srt',
        'DeliveryUrl': '/Videos/x/y/Subtitles/1/0/Stream.srt',
      });
      expect(parsed.title, 'My.Custom.Name.srt');
      expect(parsed.path, '/media/movies/My.Custom.Name.srt');
      expect(parsed.displayTitle, 'My.Custom.Name.srt');
    });
  });
}
