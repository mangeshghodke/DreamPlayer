import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/tone_map_store.dart';
import 'package:dream_player/utils/mpv_hdr_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ToneMapMode.fromString maps known values and defaults to sdr', () {
    expect(ToneMapMode.fromString('native'), ToneMapMode.native);
    expect(ToneMapMode.fromString('linear'), ToneMapMode.linear);
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
    await ToneMapStore.save(ToneMapMode.linear);
    expect(await ToneMapStore.load(), ToneMapMode.linear);
  });

  test('every HDR mode writes exactly the owned property set', () {
    for (final mode in ToneMapMode.values) {
      final properties = mpvHdrProperties(mode);
      expect(
        properties.keys.toSet(),
        mpvHdrOwnedProperties.toSet(),
        reason: 'mode ${mode.value} must write every owned property',
      );
    }
  });

  test('no mode leaves a stale target primary or transfer curve', () {
    // The bug this guards: "SDR tone-map" set target-prim/target-trc, and
    // "Native HDR/DV" only set target-colorspace-hint - so the native mode
    // inherited BT.709/BT.1886 and kept tone-mapping to SDR while the UI
    // claimed a passthrough.
    for (final mode in ToneMapMode.values) {
      final properties = mpvHdrProperties(mode);
      expect(properties['target-prim'], isNotNull, reason: mode.value);
      expect(properties['target-trc'], isNotNull, reason: mode.value);
      expect(properties['tone-mapping'], isNotNull, reason: mode.value);
      expect(properties['gamut-mapping-mode'], isNotNull, reason: mode.value);
      expect(properties['inverse-tone-mapping'], isNotNull, reason: mode.value);
    }
  });

  test('the SDR mode tone-maps to BT.709 and does not hint the display', () {
    final properties = mpvHdrProperties(ToneMapMode.sdr);
    expect(properties['target-colorspace-hint'], 'no');
    expect(properties['target-prim'], 'bt.709');
    expect(properties['target-trc'], 'bt.1886');
    expect(properties['tone-mapping'], 'spline');
    expect(properties['gamut-mapping-mode'], 'perceptual');
    expect(properties['inverse-tone-mapping'], 'no');
  });

  test('the native mode hands the source colorspace to the display', () {
    final properties = mpvHdrProperties(ToneMapMode.native);
    expect(properties['target-colorspace-hint'], 'yes');
    expect(properties['target-prim'], 'auto');
    expect(properties['target-trc'], 'auto');
    expect(properties['tone-mapping'], 'auto');
    expect(properties['gamut-mapping-mode'], 'auto');
    expect(properties['inverse-tone-mapping'], 'no');
  });

  test('the linear mode lifts SDR into HDR without shaders', () {
    final properties = mpvHdrProperties(ToneMapMode.linear);
    expect(properties['target-colorspace-hint'], 'yes');
    expect(properties['inverse-tone-mapping'], 'yes');
    expect(properties['hdr-compute-peak'], 'yes');
    expect(properties['hdr-reference-white'], '203');
    expect(properties['target-prim'], 'auto');
    expect(properties['target-trc'], 'auto');
  });

  test('only the modes that really hand HDR to the display say so', () {
    expect(ToneMapMode.native.handsHdrToDisplay, isTrue);
    expect(ToneMapMode.linear.handsHdrToDisplay, isTrue);
    expect(ToneMapMode.sdr.handsHdrToDisplay, isFalse);
  });
}
