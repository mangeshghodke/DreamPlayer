import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/plex_client.dart';

void main() {
  group('PlexClient.normalizeUrl', () {
    test('adds the default port and strips trailing slashes', () {
      expect(
        PlexClient.normalizeUrl('http://192.168.1.10'),
        'http://192.168.1.10:32400',
      );
      expect(
        PlexClient.normalizeUrl('https://my.plex.tv/'),
        'https://my.plex.tv:32400',
      );
      expect(
        PlexClient.normalizeUrl('http://host:8443/'),
        'http://host:8443',
      );
      expect(PlexClient.normalizeUrl(''), '');
    });
  });

  group('PlexServer serialization', () {
    test('round-trips and reports authentication', () {
      final server = PlexServer(
        name: 'Living room',
        url: 'http://192.168.1.10:32400',
        username: 'me@example.com',
        token: 'abc123',
        machineIdentifier: 'mach-1',
        allowSelfSigned: false,
        altUrl: null,
        autoDiscovered: false,
      );
      expect(server.isAuthenticated, isTrue);
      expect(server.urlHost, '192.168.1.10');

      final restored = PlexServer.fromJson(server.toJson());
      expect(restored.name, 'Living room');
      expect(restored.token, 'abc123');
      expect(restored.machineIdentifier, 'mach-1');

      final noToken = server.withClearedToken();
      expect(noToken.isAuthenticated, isFalse);
      expect(noToken.name, 'Living room');
    });
  });

  group('PlexItem parsing', () {
    test('section JSON becomes a folder', () {
      final item = PlexItem.fromSectionJson({
        'key': '2',
        'title': 'TV Shows',
        'type': 'show',
      });
      expect(item.id, 'section:2');
      expect(item.name, 'TV Shows');
      expect(item.isSection, isTrue);
      expect(item.isFolder, isTrue);
      expect(item.isPlayable, isFalse);
    });

    test('episode metadata carries series/episode numbers and part', () {
      final item = PlexItem.fromMetadataJson({
        '@ratingKey': '4245',
        '@title': 'Tannhaus',
        '@type': 'episode',
        '@parentRatingKey': '401',
        '@grandparentRatingKey': '300',
        '@grandparentTitle': 'Dark',
        '@parentTitle': 'Season 1',
        '@index': 5,
        '@parentIndex': 1,
        '@duration': 3240000,
        '@thumb': '/library/metadata/4245/thumb/1',
        'Media': [
          {
            'videoResolution': '1080',
            'Part': [
              {
                'id': '7711',
                'container': 'mkv',
                'size': 123456789,
              },
            ],
          },
        ],
      });
      expect(item.id, '4245');
      expect(item.name, 'Tannhaus');
      expect(item.isPlayable, isTrue);
      expect(item.isEpisode, isTrue);
      expect(item.episodeCode, 'S01E05');
      expect(item.seriesTitle, 'Dark');
      expect(item.partId, '7711');
      expect(item.container, 'mkv');
      expect(item.sizeBytes, 123456789);
      expect(item.resolutionLabel, '1080');
      expect(item.durationMs, 3240000);
    });

    test('movie metadata parses rating and year', () {
      final item = PlexItem.fromMetadataJson({
        '@ratingKey': '9',
        '@title': 'Oldboy',
        '@type': 'movie',
        '@year': 2003,
        '@rating': 8.4,
        'Media': [
          {
            'Part': [
              {'id': '10', 'container': 'mp4'},
            ],
          },
        ],
      });
      expect(item.isPlayable, isTrue);
      expect(item.year, 2003);
      expect(item.rating, 8.4);
    });

    test('show and season JSON are folders', () {
      final show = PlexItem.fromMetadataJson({
        '@ratingKey': '300',
        '@title': 'Dark',
        '@type': 'show',
      });
      final season = PlexItem.fromMetadataJson({
        '@ratingKey': '401',
        '@title': 'Season 1',
        '@type': 'season',
      });
      expect(show.isFolder, isTrue);
      expect(show.isPlayable, isFalse);
      expect(season.isFolder, isTrue);
    });

    test('json round-trip preserves the fields the UI needs', () {
      final item = const PlexItem(
        id: '4245',
        name: 'Tannhaus',
        type: 'episode',
        isFolder: false,
        index: 5,
        parentIndex: 1,
        chapters: [
          VideoChapter(title: 'Opening', startMs: 0, endMs: 90000),
        ],
      );
      final restored = PlexItem.fromJson(item.toJson());
      expect(restored.id, '4245');
      expect(restored.name, 'Tannhaus');
      expect(restored.type, 'episode');
      expect(restored.index, 5);
      expect(restored.chapters, hasLength(1));
      expect(restored.chapters.first.title, 'Opening');
    });
  });

  group('stream URLs', () {
    test('direct-play URL carries the token and container', () {
      final server = PlexServer(
        name: 'NAS',
        url: 'http://192.168.1.10:32400',
        token: 'tok',
      );
      final item = PlexItem.fromMetadataJson({
        '@ratingKey': '9',
        '@title': 'Oldboy',
        '@type': 'movie',
        'Media': [
          {
            'Part': [
              {'id': '10', 'container': 'mp4'},
            ],
          },
        ],
      });
      final url = PlexClient().streamUrlOn(server, item, 'http://192.168.1.10:32400');
      expect(
        url,
        'http://192.168.1.10:32400/library/parts/10/file.mp4?X-Plex-Token=tok',
      );
    });
  });

  group('Plex artwork URLs (library cards)', () {
    const server = PlexServer(
      name: 's',
      url: 'http://192.168.1.10:32400',
      token: 'tok',
      machineIdentifier: 'm1',
    );

    test('thumb/art paths parse from metadata and section JSON', () {
      final item = PlexItem.fromMetadataJson({
        'ratingKey': '5',
        'type': 'movie',
        'title': 'Movie',
        'thumb': '/library/metadata/5/thumb/1',
        'art': '/library/metadata/5/art/1',
      });
      expect(item.thumbPath, '/library/metadata/5/thumb/1');
      expect(item.artPath, '/library/metadata/5/art/1');
      final section = PlexItem.fromSectionJson({
        'key': '1',
        'title': 'Movies',
        'type': 'movie',
        'thumb': '/library/sections/1/thumb',
        'art': '/library/sections/1/art',
      });
      expect(section.artPath, '/library/sections/1/art');
    });

    test('thumbUrl/artUrl build absolute token URLs', () {
      final client = PlexClient();
      final item = PlexItem(
        id: '5',
        name: 'Movie',
        type: 'movie',
        isFolder: false,
        thumbPath: '/library/metadata/5/thumb/1',
        artPath: '/library/metadata/5/art/1',
      );
      expect(client.thumbUrl(server, item),
          'http://192.168.1.10:32400/library/metadata/5/thumb/1?X-Plex-Token=tok');
      expect(client.artUrl(server, item),
          'http://192.168.1.10:32400/library/metadata/5/art/1?X-Plex-Token=tok');
      final noArt = PlexItem(id: '6', name: 'X', type: 'movie', isFolder: false);
      expect(client.thumbUrl(server, noArt), null);
      expect(client.artUrl(server, noArt), null);
    });

    test('plex browser shows the card grid at libraries level and thumbs inside', () {
      final src = File('lib/screens/plex_screen.dart').readAsStringSync();
      expect(src, contains('LibraryCardGrid('));
      expect(src, contains('_crumbs.isEmpty'));
      expect(src, contains('_client.artUrl(server, _items[i]) ??'));
      expect(src, contains('_client.thumbUrl(server, item)'));
      expect(src, contains('EpisodePosterThumb(posterUrl: thumbUrl'));
    });
  });
}
