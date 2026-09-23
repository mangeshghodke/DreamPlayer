import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/tone_map_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ToneMapMode.fromString maps known values and defaults to sdr', () {
    expect(ToneMapMode.fromString('native'), ToneMapMode.native);
    expect(ToneMapMode.fromString('sdr'), ToneMapMode.sdr);
    expect(ToneMapMode.fromString(null), ToneMapMode.sdr);
    expect(ToneMapMode.fromString('bogus'), ToneMapMode.sdr);
  });

  test('ToneMapStore load/save round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await ToneMapStore.load(), ToneMapMode.sdr);
    await ToneMapStore.save(ToneMapMode.native);
    expect(await ToneMapStore.load(), ToneMapMode.native);
    await ToneMapStore.save(ToneMapMode.sdr);
    expect(await ToneMapStore.load(), ToneMapMode.sdr);
  });
}
