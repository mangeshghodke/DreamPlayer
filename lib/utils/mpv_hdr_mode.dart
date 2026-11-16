import '../services/tone_map_store.dart';

/// Every mpv property the HDR presentation mode owns.
///
/// A mode switch writes **all** of them, every time. That is the whole point:
/// mpv keeps the previous value of any property it is not told about, so a
/// mode that only sets what it needs inherits whatever the previous mode
/// left behind. The concrete symptom was the "Native HDR/DV" mode still
/// forcing BT.709/BT.1886 output, because the previous "SDR tone-map" mode
/// had set `target-prim`/`target-trc` and native never reset them - so the
/// picture stayed tone-mapped and SDR while the UI claimed otherwise.
///
/// The set is asserted in the unit test: every mode must produce exactly
/// these keys, no more and no less.
const List<String> mpvHdrOwnedProperties = <String>[
  'target-colorspace-hint',
  'target-colorspace-hint-mode',
  'target-prim',
  'target-trc',
  'target-peak',
  'tone-mapping',
  'gamut-mapping-mode',
  'inverse-tone-mapping',
  'hdr-compute-peak',
  'hdr-reference-white',
];

/// The complete mpv property set for one HDR presentation mode.
///
/// Pure on purpose: the invariant "every mode writes the same keys" is then
/// a plain unit test instead of something that can only be discovered on a
/// device, by looking at a washed-out picture.
Map<String, String> mpvHdrProperties(ToneMapMode mode) {
  final common = <String, String>{
    'target-colorspace-hint-mode': 'target',
    'target-peak': 'auto',
    'hdr-reference-white': '203',
  };
  return switch (mode) {
    // libplacebo tone-maps HDR/DV down to a BT.709/BT.1886 SDR signal.
    ToneMapMode.sdr => {
        ...common,
        'target-colorspace-hint': 'no',
        'target-prim': 'bt.709',
        'target-trc': 'bt.1886',
        'tone-mapping': 'spline',
        'gamut-mapping-mode': 'perceptual',
        'inverse-tone-mapping': 'no',
        'hdr-compute-peak': 'no',
      },
    // Hand the source colorspace to the display: SurfaceFlinger/panel does the
    // HDR work. Every target value is reset, or the previous mode's
    // tone-mapping would still be applied on top of the passthrough.
    ToneMapMode.native => {
        ...common,
        'target-colorspace-hint': 'yes',
        'target-prim': 'auto',
        'target-trc': 'auto',
        'tone-mapping': 'auto',
        'gamut-mapping-mode': 'auto',
        'inverse-tone-mapping': 'no',
        'hdr-compute-peak': 'auto',
      },
    // Linear HDR: mpv-native, no shaders. Inverse tone mapping lifts an SDR
    // signal into the HDR range (inverse-tone-mapping + hdr-compute-peak),
    // and the output is handed to the display as HDR.
    ToneMapMode.linear => {
        ...common,
        'target-colorspace-hint': 'yes',
        'target-prim': 'auto',
        'target-trc': 'auto',
        'tone-mapping': 'auto',
        'gamut-mapping-mode': 'auto',
        'inverse-tone-mapping': 'yes',
        'hdr-compute-peak': 'yes',
      },
    // The hdr-toys profiles: the GLSL chain owns transfer, gamut and tone,
    // so gpu-next must NOT negotiate a second HDR transform on top of it -
    // that is why the colorspace hint is off and the tone-mapping is
    // "clip" (the shaders do the work).
    ToneMapMode.pq => _hdrToys('bt.2020', 'pq'),
    ToneMapMode.hlg => _hdrToys('bt.2020', 'hlg'),
    ToneMapMode.bt2020 => _hdrToys('bt.2020', 'bt.1886'),
  };
}

Map<String, String> _hdrToys(String targetPrim, String targetTrc) {
  return {
    'target-colorspace-hint-mode': 'target',
    'target-peak': 'auto',
    'hdr-reference-white': '203',
    'target-colorspace-hint': 'no',
    'target-prim': targetPrim,
    'target-trc': targetTrc,
    'tone-mapping': 'clip',
    'gamut-mapping-mode': 'clip',
    'inverse-tone-mapping': 'no',
    'hdr-compute-peak': 'no',
  };
}
