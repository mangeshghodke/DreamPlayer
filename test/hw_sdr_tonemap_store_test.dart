import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/hw_sdr_tonemap_store.dart';

/// Hardware SDR tone-mapping (issue #55) is OFF by default - the HDR/DV
/// passthrough is the app's headline feature and this setting trades it away
/// on purpose.
///
/// The key name is part of the contract with the native side: shared_preferences
/// stores it in `FlutterSharedPreferences` under `flutter.` + the key, and the
/// Android codec adapter reads exactly that string.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to off', () async {
    expect(await HwSdrToneMapStore.load(), isFalse);
  });

  test('round-trips the enabled state', () async {
    await HwSdrToneMapStore.save(true);
    expect(await HwSdrToneMapStore.load(), isTrue);
    await HwSdrToneMapStore.save(false);
    expect(await HwSdrToneMapStore.load(), isFalse);
  });

  test('uses the key the native side reads', () async {
    await HwSdrToneMapStore.save(true);
    final prefs = await SharedPreferences.getInstance();
    // The Dart-side key is unprefixed; the Android plugin writes it into
    // `FlutterSharedPreferences` as `flutter.` + the key, which is exactly
    // what `HwSdrToneMap.isEnabled` reads on the native side.
    expect(prefs.getBool(HwSdrToneMapStore.prefsKey), isTrue);
    expect(HwSdrToneMapStore.prefsKey, 'dreamplayer.hwSdrToneMap');
  });
}
