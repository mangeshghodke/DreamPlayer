import 'package:dream_player/services/anime4k_shader_store.dart';

/// How hot the device is, as far as the GPU-heavy picture features care.
///
/// The numbers come from Android's `PowerManager.getThermalHeadroom(10)`,
/// which answers from 0 (about to throttle) to 1 (comfortable). The policy
/// that turns that number into a quality tier is ours - the platform only
/// publishes the reading.
enum ThermalTier {
  /// No reading, or the device is comfortable.
  normal,

  /// Getting warm: the extra frame rate is no longer worth the heat.
  mild,

  /// Hot: the picture effects have to step down.
  hot,

  /// About to throttle: the GPU extras are switched off.
  critical;

  bool get isThrottled => this != ThermalTier.normal;
}

/// The tier a headroom reading falls into.
///
/// A reading below 0 (the platform's "no answer") is *not* a tier change -
/// it means the platform cannot tell us, so the quality is left alone.
ThermalTier thermalTierFor(double headroom) {
  if (headroom < 0) return ThermalTier.normal;
  if (headroom < 0.40) return ThermalTier.critical;
  if (headroom < 0.60) return ThermalTier.hot;
  if (headroom < 0.80) return ThermalTier.mild;
  return ThermalTier.normal;
}

/// What the picture features are allowed to do at a given [ThermalTier].
class ThermalQualityLimit {
  const ThermalQualityLimit({
    required this.maxInterpolationFps,
    required this.allowAnime4k,
    this.maxAnime4kMode,
  });

  /// The highest frame-interpolation target allowed. 0 means "no
  /// interpolation" - the frames are the source's own.
  final int maxInterpolationFps;

  /// Whether the Anime4K upscaler may run at all.
  final bool allowAnime4k;

  /// The most expensive Anime4K preset allowed. `null` means the user's own
  /// choice is kept.
  final Anime4kMode? maxAnime4kMode;
}

/// The limit that belongs to [tier].
ThermalQualityLimit thermalLimitFor(ThermalTier tier) {
  switch (tier) {
    case ThermalTier.normal:
      return const ThermalQualityLimit(
        maxInterpolationFps: 120,
        allowAnime4k: true,
      );
    case ThermalTier.mild:
      return const ThermalQualityLimit(
        maxInterpolationFps: 60,
        allowAnime4k: true,
      );
    case ThermalTier.hot:
      return const ThermalQualityLimit(
        maxInterpolationFps: 48,
        allowAnime4k: true,
      );
    case ThermalTier.critical:
      return const ThermalQualityLimit(
        maxInterpolationFps: 0,
        allowAnime4k: false,
      );
  }
}

/// One notch down the Anime4K ladder.
///
/// The ladder is ordered by cost: the single-pass modes are cheapest, the
/// double-pass ones (A+A, B+B, C+A) are the most expensive, so they are the
/// first to go.
Anime4kMode stepDownAnime4k(Anime4kMode mode) {
  switch (mode) {
    case Anime4kMode.a:
      return Anime4kMode.a;
    case Anime4kMode.b:
      return Anime4kMode.a;
    case Anime4kMode.c:
      return Anime4kMode.b;
    case Anime4kMode.aa:
      return Anime4kMode.a;
    case Anime4kMode.bb:
      return Anime4kMode.aa;
    case Anime4kMode.ca:
      return Anime4kMode.aa;
  }
}

/// The Anime4k preset a [mode] has to fall back to at [tier].
///
/// `null` means "no change" - either the tier does not touch the preset, or
/// the preset is already the cheapest one.
Anime4kMode? anime4kModeForTier(ThermalTier tier, Anime4kMode mode) {
  if (tier != ThermalTier.hot) return null;
  final stepped = stepDownAnime4k(mode);
  return stepped == mode ? null : stepped;
}
