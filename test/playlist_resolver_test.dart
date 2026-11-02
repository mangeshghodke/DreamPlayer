import 'package:flutter_test/flutter_test.dart';
import 'package:dream_player/services/playlist_resolver.dart';

void main() {
  group('isStrmFile / isM3uFile', () {
    test('strm matches case-insensitively', () {
      expect(PlaylistResolver.isStrmFile('Movie.STRM'), isTrue);
      expect(PlaylistResolver.isStrmFile('movie.strm'), isTrue);
      expect(PlaylistResolver.isStrmFile('movie.mkv'), isFalse);
      expect(PlaylistResolver.isStrmFile('strm'), isFalse);
    });

    test('m3u and m3u8 match', () {
      expect(PlaylistResolver.isM3uFile('list.m3u'), isTrue);
      expect(PlaylistResolver.isM3uFile('list.M3U8'), isTrue);
      expect(PlaylistResolver.isM3uFile('list.m3u.txt'), isFalse);
    });
  });

  group('dirOf', () {
    test('returns the directory portion', () {
      expect(PlaylistResolver.dirOf('a/b/c.mkv'), 'a/b');
      expect(PlaylistResolver.dirOf('c.mkv'), '');
      expect(PlaylistResolver.dirOf('/c.mkv'), '');
    });
  });

  group('parseM3u', () {
    test('parses EXTINF names and skips comments/blanks', () {
      const content = '#EXTM3U\n'
          '#EXTINF:-1,Movie One\n'
          'http://nas/movies/one.mkv\n'
          '\n'
          '#EXTINF:-1,Movie Two\n'
          'http://nas/movies/two.mkv\n';
      final entries = PlaylistResolver.parseM3u(content);
      expect(entries, hasLength(2));
      expect(entries[0].name, 'Movie One');
      expect(entries[0].url, 'http://nas/movies/one.mkv');
      expect(entries[1].name, 'Movie Two');
    });

    test('bare URLs get an empty name', () {
      final entries = PlaylistResolver.parseM3u('relative/clip.mp4\r\n');
      expect(entries, hasLength(1));
      expect(entries.single.name, '');
      expect(entries.single.url, 'relative/clip.mp4');
    });

    test('empty content yields no entries', () {
      expect(PlaylistResolver.parseM3u('#EXTM3U\n\n'), isEmpty);
    });
  });

  group('resolveRef', () {
    test('absolute URLs pass through', () {
      expect(
        PlaylistResolver.resolveRef('http://a/b/', 'smb://x/y/z.mkv'),
        'smb://x/y/z.mkv',
      );
      expect(
        PlaylistResolver.resolveRef('http://a/b/', 'https://c/d.mkv'),
        'https://c/d.mkv',
      );
    });

    test('relative refs resolve against the base directory', () {
      expect(
        PlaylistResolver.resolveRef('http://nas/share/dir/', 'clip.mkv'),
        'http://nas/share/dir/clip.mkv',
      );
      expect(
        PlaylistResolver.resolveRef('http://nas/share/dir', '../up.mkv'),
        'http://nas/share/up.mkv',
      );
    });

    test('base without trailing slash is treated as a directory', () {
      expect(
        PlaylistResolver.resolveRef('http://nas/share/dir', 'clip.mkv'),
        'http://nas/share/dir/clip.mkv',
      );
    });

    test('empty ref returns empty', () {
      expect(PlaylistResolver.resolveRef('http://a/', '   '), '');
    });
  });

  group('strmTarget', () {
    test('first non-empty line wins', () {
      expect(
        PlaylistResolver.strmTarget('\n  http://nas/movie.mkv  \nignored\n'),
        'http://nas/movie.mkv',
      );
    });

    test('blank content returns null', () {
      expect(PlaylistResolver.strmTarget('\n\n'), isNull);
    });
  });

  group('resolveToVideoItem', () {
    test('strm resolves to a URI VideoItem with strm-scoped resume key', () async {
      final item = await PlaylistResolver.resolveToVideoItem(
        name: 'Movie.strm',
        selfRef: 'smb://srv/share/Movies/Movie.strm',
        baseForRelative: 'smb://srv/share/Movies/',
        resumeKeyPrefix: 'smb:srv/share',
        fetchTextAt: (ref) async =>
            ref.endsWith('.strm') ? 'http://cdn/movie.mkv\n' : null,
      );
      expect(item, isNotNull);
      expect(item!.uri, 'http://cdn/movie.mkv');
      expect(item.path, isNull);
      expect(item.resumeKey, 'strm:smb:srv/share/Movie.strm');
      expect(item.title, 'Movie');
    });

    test('strm with file:// target becomes a local path', () async {
      final item = await PlaylistResolver.resolveToVideoItem(
        name: 'Clip.strm',
        selfRef: '/media/clip.strm',
        baseForRelative: 'file:///media/clip.strm',
        resumeKeyPrefix: 'file:/media/clip.strm',
        fetchTextAt: (ref) async => 'file:///media/real.mkv',
      );
      expect(item, isNotNull);
      expect(item!.path, '/media/real.mkv');
      expect(item.uri, isNull);
    });

    test('m3u resolves to the first entry', () async {
      final item = await PlaylistResolver.resolveToVideoItem(
        name: 'list.m3u',
        selfRef: 'http://nas/list.m3u',
        baseForRelative: 'http://nas/',
        resumeKeyPrefix: 'webdav_srv',
        fetchTextAt: (ref) async => ref.endsWith('.m3u')
            ? '#EXTM3U\n#EXTINF:-1,Part 1\npart1.mkv\n#EXTINF:-1,Part 2\npart2.mkv\n'
            : null,
      );
      expect(item, isNotNull);
      expect(item!.uri, 'http://nas/part1.mkv');
      expect(item.title, 'Part 1');
      expect(item.resumeKey, 'm3u:webdav_srv/list.m3u');
    });

    test('unreadable strm returns null', () async {
      final item = await PlaylistResolver.resolveToVideoItem(
        name: 'x.strm',
        selfRef: 'x.strm',
        baseForRelative: '',
        resumeKeyPrefix: 'p',
        fetchTextAt: (_) async => null,
      );
      expect(item, isNull);
    });

    test('non-playlist name returns null without fetching', () async {
      var fetched = false;
      final item = await PlaylistResolver.resolveToVideoItem(
        name: 'movie.mkv',
        selfRef: 'movie.mkv',
        baseForRelative: '',
        resumeKeyPrefix: 'p',
        fetchTextAt: (_) async {
          fetched = true;
          return 'x';
        },
      );
      expect(item, isNull);
      expect(fetched, isFalse);
    });
  });

  group('decodeText', () {
    test('decodes utf8 and tolerates malformed bytes', () {
      expect(PlaylistResolver.decodeText(null), isNull);
      expect(PlaylistResolver.decodeText([0x68, 0x69]), 'hi');
      expect(PlaylistResolver.decodeText([0xff, 0xfe, 0x41]), isNotNull);
    });
  });
}
