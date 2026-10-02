import 'package:dream_player/services/mpv_downmix_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Issue #37: the MPV engine was noticeably quieter than Media3 for the same
/// file, because `audio-normalize-downmix` was forced on. mpv's manual says of
/// the enabled case that "the output might be too silent", and `no` is mpv's own
/// default — so the off state has to be the default here too.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('MpvDownmixStore', () {
    test('defaults to off so the engines match', () async {
      expect(await MpvDownmixStore.load(), isFalse);
    });

    test('round-trips a saved value', () async {
      await MpvDownmixStore.save(true);
      expect(await MpvDownmixStore.load(), isTrue);
      await MpvDownmixStore.save(false);
      expect(await MpvDownmixStore.load(), isFalse);
    });

    test('survives an unrelated pref write', () async {
      await MpvDownmixStore.save(true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('something.else', true);
      expect(await MpvDownmixStore.load(), isTrue);
    });
  });
}
