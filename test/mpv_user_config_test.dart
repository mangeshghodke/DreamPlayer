import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/mpv_user_config.dart';
import 'package:dream_player/utils/mpv_interpolation.dart' show MpvOption;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseMpvConf', () {
    test('parses key=value, no-key, bare key, comments, quotes', () {
      final r = parseMpvConf('''
# a comment
deband=yes
no-cache
volume = 80
sub-font="Fira Code"
''');
      expect(r.options, containsAllInOrder([
        const MpvOption('deband', 'yes'),
        const MpvOption('cache', 'no'),
        const MpvOption('volume', '80'),
        const MpvOption('sub-font', 'Fira Code'),
      ]));
      expect(r.warnings, isEmpty);
    });

    test('protected and init-only keys are skipped with a warning', () {
      final r = parseMpvConf('''
vo=null
wid=1234
force-window=yes
load-scripts=yes
script=/tmp/evil.lua
config-dir=/sdcard/evil
deband=yes
''');
      expect(r.options, [const MpvOption('deband', 'yes')]);
      expect(r.warnings, contains('"vo" is init-only/protected, skipped'));
      expect(r.warnings, contains('"load-scripts" is init-only/protected, skipped'));
      expect(r.warnings, contains('"script" is init-only/protected, skipped'));
      expect(r.warnings, contains('"config-dir" is init-only/protected, skipped'));
    });

    test('profile sections are skipped with a warning', () {
      final r = parseMpvConf('''
deband=yes
[gpu-hq]
scale=ewa_lanczossharp
[fast]
profile=fast
''');
      expect(r.options, [const MpvOption('deband', 'yes')]);
      expect(r.warnings, contains('profile section gpu-hq skipped'));
      expect(r.warnings, contains('profile section fast skipped'));
    });

    test('include= resolves through includeFiles relative to baseDir', () {
      final r = parseMpvConf(
        'include=extra.conf\ndeband=yes\n',
        baseDir: '/sdcard/mpv',
        includeFiles: {
          '/sdcard/mpv/extra.conf': 'dither=ordered\n',
        },
      );
      expect(r.options, containsAllInOrder([
        const MpvOption('dither', 'ordered'),
        const MpvOption('deband', 'yes'),
      ]));
    });

    test('missing include is a warning, not a crash; depth cap holds', () {
      final r = parseMpvConf(
        'include=nope.conf\n',
        baseDir: '/x',
        includeFiles: {},
      );
      expect(r.options, isEmpty);
      expect(r.warnings, contains('include "nope.conf" not readable, skipped'));

      // Self-including file must terminate via the depth cap.
      final loop = parseMpvConf(
        'include=loop.conf\n',
        baseDir: '/x',
        includeFiles: {'/x/loop.conf': 'include=loop.conf\n'},
      );
      expect(loop.warnings, contains(contains('depth cap')));
    });

    test('empty and garbage lines are ignored', () {
      final r = parseMpvConf('\n\n   \n# only comments\n=novalue\n');
      expect(r.options, isEmpty);
    });
  });

  group('MpvUserConfigStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('load returns nulls when nothing saved', () async {
      final cfg = await MpvUserConfigStore.load();
      expect(cfg.uri, isNull);
      expect(cfg.name, isNull);
    });

    test('save/load round-trips uri and name; clear removes both', () async {
      await MpvUserConfigStore.save(uri: 'content://x/y', name: 'mpv.conf');
      var cfg = await MpvUserConfigStore.load();
      expect(cfg.uri, 'content://x/y');
      expect(cfg.name, 'mpv.conf');
      await MpvUserConfigStore.clear();
      cfg = await MpvUserConfigStore.load();
      expect(cfg.uri, isNull);
      expect(cfg.name, isNull);
    });
  });
}
