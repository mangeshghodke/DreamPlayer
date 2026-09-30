import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/utils/media_junk_filter.dart';

void main() {
  group('isJunkDirectory', () {
    test('excludes extras folders found in a real library', () {
      for (final name in [
        'Featurettes',
        'featurettes',
        'Extras',
        'Special Features',
        'special_features',
        'Behind the Scenes',
        'Trailers',
        'Sample',
        'Subs',
        'Artwork',
      ]) {
        expect(isJunkDirectory(name), isTrue, reason: name);
      }
    });

    test('excludes hidden player/tool state directories', () {
      // `.thumbnails` was showing up as its own library card.
      for (final name in ['.thumbnails', '.DS_Store', '.Trash', '@eaDir']) {
        expect(isJunkDirectory(name), isTrue, reason: name);
      }
    });

    test('keeps real movie and series folders', () {
      for (final name in [
        'Avengers',
        'Avengers.Endgame.2019.IMAX.2160p',
        'Harry Potter Series',
        'Home Alone (1990) RM4K (1080p BluRay x265)',
        'Golmaal Marathi',
        'Chup Chup Ke 2006',
        'De Dhakka 2008',
        'The Exorcist',
        'Extraordinary Measures',
        'Collection 2',
      ]) {
        expect(isJunkDirectory(name), isFalse, reason: name);
      }
    });
  });

  group('isJunkFile', () {
    test('excludes artwork and player state sidecars', () {
      for (final name in [
        'folder.jpg',
        'backdrop.jpg',
        'poster.png',
        'logo.png',
        'landscape.jpg',
        'Tanu Weds Manu 2011 BluRay 1080p - mkvCinemas [Telly]-backdrop.jpg',
        'Swades - We, the People.srt',
        '.Avengers.Endgame.2019.mkv.46.archos.resume.xml',
        'movie.nfo',
        'playlist.m3u',
      ]) {
        expect(isJunkFile(name), isTrue, reason: name);
      }
    });

    test('excludes short trailer / featurette files', () {
      for (final name in [
        'Trailer 1.mkv',
        'Trailer.mkv',
        'Trailer 3.mp4',
        'Trailer HD.mkv',
        'Behind the Scenes.mkv',
        'Bloopers.mkv',
        'Blooper Reel.mkv',
        'Sample.mkv',
      ]) {
        expect(isJunkFile(name), isTrue, reason: name);
      }
    });

    test('keeps real videos', () {
      for (final name in [
        'Avengers.Endgame.2019.IMAX.2160p.DSNP.WEB-DL.HIN-ENG.TrueHD.7.1.'
            'Atmos.DoVi.HDR.HEVC-SiC_3.mkv',
        'Interstellar.2014.IMAX.2160p.UHD.BluRay.REMUX.mkv',
        'Top Gun - Maverick (2022) IMAX 2160p 4K UHD.mkv',
        'Home Alone (1990) RM4K (1080p BluRay x265 10bit Tigole).mkv',
        'Swades - We, the People.mp4',
        'Harry.Potter.and.the.Sorcerers.Stone.2001.mkv',
        'golmaal.mkv',
      ]) {
        expect(isJunkFile(name), isFalse, reason: name);
      }
    });

    test('does not swallow a real film that starts with a junk word', () {
      // The junk prefix only applies when a number/qualifier follows it.
      expect(isJunkFile('Trailer Park Boys.mkv'), isFalse);
      expect(isJunkFile('Making of Love (1983).mkv'), isFalse);
      // A long featurette title is caught by its *directory* instead.
      expect(isJunkDirectory('Featurettes'), isTrue);
    });
  });
}
