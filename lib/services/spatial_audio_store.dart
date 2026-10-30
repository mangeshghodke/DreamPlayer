import 'package:shared_preferences/shared_preferences.dart';

import 'entitlements.dart';

/// Whether the premium spatial-audio opt-in may be turned on right now.
///
/// Spatial audio is a paid feature, so a free user who flips the switch gets
/// the paywall instead of the feature. [advanced] is
/// `Entitlements.instance.isEntitled` (paying OR in-trial) and [paywallActive]
/// is `Entitlements.instance.effectivePaywallEnabled`.
bool spatialAudioMayBeEnabled({
  required bool advanced,
  required bool paywallActive,
}) {
  return checkGate(
    gateEnabled: true,
    advanced: advanced,
    paywallActive: paywallActive,
  ) != GateResult.paywallNeeded;
}

/// Whether Apple's system spatialization is opted into on iOS.
///
/// Default OFF: spatial audio is a paid feature, so a free user never has it
/// enabled. The toggle in Settings -> Audio is what turns it on, and that
/// toggle is paywall-gated.
///
/// The pref key is read natively as `flutter.dreamplayer.spatialAudio`
/// (shared_preferences prefixes its keys on iOS), which is how the native
/// side learns the preference without a channel round trip.
class SpatialAudioStore {
  SpatialAudioStore._();

  static const String prefsKey = 'dreamplayer.spatialAudio';

  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) ?? false;
  }

  static Future<void> save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, enabled);
  }

  /// The value the native side must act on: the saved preference, but only
  /// while the user is still entitled.
  ///
  /// The native side reads the pref directly (it is the only way it learns
  /// the preference without a channel round trip), so a lapsed subscription
  /// or an expired trial would otherwise leave the paid feature switched on
  /// for free. This turns it off and persists the correction, which the next
  /// native read then picks up.
  static Future<bool> effectiveEnabled() async {
    final saved = await load();
    final ent = Entitlements.instance;
    if (saved && ent.effectivePaywallEnabled && !ent.isEntitled) {
      await save(false);
      return false;
    }
    return saved;
  }
}
