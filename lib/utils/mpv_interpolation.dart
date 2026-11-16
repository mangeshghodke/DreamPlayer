/// Frame interpolation for the libmpv engine (issue #53).
///
/// mpv generates the frames that are missing between a source's own frames,
/// so 24 fps anime can be shown as 48 fps. It is a **libmpv-only** feature:
/// Media3 hands decoded frames straight to the SurfaceView, so there is no
/// renderer in which an extra frame could be produced.
///
/// Three mpv details decide whether it works at all:
///
///  * `--interpolation` is silently ignored unless `--video-sync` is one of
///    the `display-*` modes, so the sync mode has to be switched as well.
///  * The frame rate mpv interpolates *to* is the display frame rate, so the
///    target is set with `--display-fps-override` (mpv renamed it from
///    `--display-fps`; in the newer builds the old name is also a read-only
///    property, so it has to be applied with a read-back check).
///  * `--interpolation-threshold` (default 0.01) switches interpolation off
///    when the two frame rates are within 1% of each other, which would make
///    a 47.94 fps source on a 48 fps target do nothing. -1 turns that logic
///    off.
enum MpvInterpolationFilter {
  /// mpv's `oversample` filter - the one usually known as **SmoothMotion**
  /// (AMD FSR 1.0 style). The sharpest of the three.
  oversample('oversample'),

  /// Linear blend - softer edges, more ghosting on fast motion.
  linear('linear'),

  /// Bicubic - the smoothest and blurriest; the safest on clean animation.
  bicubic('bicubic');

  const MpvInterpolationFilter(this.mpvName);

  /// The value mpv expects for `--tscale`.
  final String mpvName;
}

/// The user's frame-interpolation choice.
class MpvInterpolationConfig {
  const MpvInterpolationConfig({
    this.targetFps = 0,
    this.filter = MpvInterpolationFilter.oversample,
  });

  /// The frame rate to interpolate to. 0 means "off".
  final int targetFps;

  /// The temporal filter mpv convolves the frames with.
  final MpvInterpolationFilter filter;

  bool get enabled => targetFps > 0;

  MpvInterpolationConfig copyWith({
    int? targetFps,
    MpvInterpolationFilter? filter,
  }) {
    return MpvInterpolationConfig(
      targetFps: targetFps ?? this.targetFps,
      filter: filter ?? this.filter,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is MpvInterpolationConfig &&
        other.targetFps == targetFps &&
        other.filter == filter;
  }

  @override
  int get hashCode => Object.hash(targetFps, filter);
}

/// A single mpv option to apply.
class MpvOption {
  const MpvOption(this.name, this.value);

  final String name;
  final String value;

  @override
  bool operator ==(Object other) {
    return other is MpvOption && other.name == name && other.value == value;
  }

  @override
  int get hashCode => Object.hash(name, value);
}

/// The mpv options that turn interpolation on (or off) for [config].
///
/// The target frame rate is not in this list: its option name differs
/// between mpv versions and the old name doubles as a read-only property,
/// so it is applied separately - see [mpvDisplayFpsOptionNames].
List<MpvOption> mpvInterpolationOptions(MpvInterpolationConfig config) {
  if (!config.enabled) {
    return const [
      MpvOption('interpolation', 'no'),
      MpvOption('video-sync', 'audio'),
    ];
  }
  return [
    const MpvOption('video-sync', 'display-resample'),
    const MpvOption('interpolation', 'yes'),
    MpvOption('tscale', config.filter.mpvName),
    const MpvOption('interpolation-threshold', '-1'),
  ];
}

/// The mpv option/property names that can carry the target frame rate.
///
/// mpv keeps the *option* value and the *detected* refresh rate apart: the
/// detected one is the read-only `display-fps` property, while the option
/// value lives in `override-display-fps` ("the reported value and the option
/// value are cleanly separated (override-display-fps for the option value)" -
/// mpv's manual). The user-facing option was renamed from `--display-fps` to
/// `--display-fps-override` along the way, so all three names are tried and
/// every one of them is read back before it counts.
const List<String> mpvDisplayFpsOptionNames = [
  'override-display-fps',
  'display-fps-override',
  'display-fps',
];
