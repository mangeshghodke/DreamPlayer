import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether `PAYWALL_ENABLED` was passed at build time.
const bool paywallEnabled = bool.fromEnvironment('PAYWALL_ENABLED', defaultValue: false);

/// SharedPreferences keys for debug overrides and the trial start time.
const String _kDebugFreeUser = 'dreamplayer.debugFreeUser';
const String _kDebugTrialExpired = 'dreamplayer.debugTrialExpired';
const String _kTrialStartedAt = 'dreamplayer.trialStartedAt';

/// Duration of the free trial (wall clock, started at first relevant launch).
const Duration trialDuration = Duration(days: 7);

/// Single source of truth for "is the user advanced?".
///
/// Android: `advanced` is ALWAYS `true` — the getter ORs the platform in,
/// so no code path can make Android "not advanced".
/// iOS: reads StoreKit 2 `Transaction.currentEntitlements` (via the purchase
/// stream). Initially false until a purchase is confirmed.
/// Debug override: when `debugFreeUser == true`, `isAdvanced` is `false` on
/// ALL platforms — lets us test the paywall on Android without an Apple account.
class Entitlements extends ChangeNotifier {
  Entitlements._();
  static final Entitlements instance = Entitlements._();

  bool _advanced = false;
  bool _debugFreeUser = false;
  bool _debugTrialExpired = false;

  /// Milliseconds since epoch when the 7-day free trial started (null = not started).
  int? _trialStartedAtMs;

  /// Android is permanently advanced (immunity guarantee).
  bool get advanced => defaultTargetPlatform == TargetPlatform.android || _advanced;

  bool get debugFreeUser => _debugFreeUser;
  bool get debugTrialExpired => _debugTrialExpired;

  /// Wall-clock 7-day free trial. Starts on the first launch where the paywall
  /// is actually active (real builds on iOS, or the debug-simulated build on
  /// Android) — later launches that have the paywall off never start a trial.
  bool get trialActive {
    final start = _trialStartedAtMs;
    if (start == null || _debugTrialExpired) return false;
    if (defaultTargetPlatform == TargetPlatform.android && !_debugFreeUser) {
      // Android (real) is always advanced — the trial never matters there.
      return false;
    }
    return DateTime.now().millisecondsSinceEpoch - start < trialDuration.inMilliseconds;
  }

  /// How much of the trial is left (Duration.zero when inactive/expired).
  Duration get trialRemaining {
    final start = _trialStartedAtMs;
    if (start == null || !trialActive) return Duration.zero;
    final rem = trialDuration.inMilliseconds - (DateTime.now().millisecondsSinceEpoch - start);
    return Duration(milliseconds: rem < 0 ? 0 : rem);
  }

  /// Effective "advanced" that respects the debug override.
  bool get isAdvanced => _debugFreeUser ? false : advanced;

  /// Effective entitlement for gates: a paying user OR an in-trial user.
  /// Trial users pass every gate; after the trial the paywall engages.
  bool get isEntitled => isAdvanced || trialActive;

  /// Effective "paywall enabled" that respects the debug override.
  /// On Android paywallEnabled is false by default, but when debugFreeUser
  /// is true we override it to true so gates actually fire for testing.
  bool get effectivePaywallEnabled =>
      paywallEnabled || (_debugFreeUser && defaultTargetPlatform == TargetPlatform.android);

  bool _initialised = false;
  bool get initialised => _initialised;

  /// Call once at app start.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      _debugFreeUser = prefs.getBool(_kDebugFreeUser) ?? false;
      _debugTrialExpired = prefs.getBool(_kDebugTrialExpired) ?? false;
      _trialStartedAtMs = prefs.getInt(_kTrialStartedAt);
    } catch (_) {}

    // Start the 7-day trial on the first launch where the paywall is relevant.
    if (_trialStartedAtMs == null && effectivePaywallEnabled) {
      _trialStartedAtMs = DateTime.now().millisecondsSinceEpoch;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_kTrialStartedAt, _trialStartedAtMs!);
      } catch (_) {}
    }

    // Listen for StoreKit transactions (iOS only, when paywall is active).
    if (defaultTargetPlatform != TargetPlatform.android &&
        (paywallEnabled || _debugFreeUser)) {
      InAppPurchase.instance.purchaseStream.listen(_onPurchaseUpdate);
    }
  }

  void _onPurchaseUpdate(List<PurchaseDetails> purchases) {
    for (final p in purchases) {
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        _advanced = true;
        _debugFreeUser = false; // real purchase overrides debug
        notifyListeners();
        return;
      }
    }
  }

  /// Toggle the debug "simulate free user" override.
  Future<void> setDebugFreeUser(bool value) async {
    _debugFreeUser = value;
    if (!value) _advanced = false; // reset to platform default (Android stays gated-true)
    // Flipping the override on later also starts the trial (if never started),
    // so the "free user on Android" simulation behaves like a real iOS user.
    if (value && _trialStartedAtMs == null) {
      _trialStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDebugFreeUser, value);
      if (_trialStartedAtMs != null) {
        await prefs.setInt(_kTrialStartedAt, _trialStartedAtMs!);
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Toggle the debug "simulate trial expired" override.
  Future<void> setDebugTrialExpired(bool value) async {
    _debugTrialExpired = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDebugTrialExpired, value);
    } catch (_) {}
    notifyListeners();
  }

  /// Buy a product. Returns true if the transaction initiated successfully.
  Future<bool> buy(String productId) async {
    if (defaultTargetPlatform == TargetPlatform.android && !_debugFreeUser) return false;
    final available = await InAppPurchase.instance.isAvailable();
    if (!available) return false;
    final details = await InAppPurchase.instance.queryProductDetails({productId});
    if (details.productDetails.isEmpty) return false;
    final param = PurchaseParam(productDetails: details.productDetails.first);
    final success = await InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
    return success;
  }

  /// Restore purchases.
  Future<void> restorePurchases() async {
    if (defaultTargetPlatform == TargetPlatform.android && !_debugFreeUser) return;
    await InAppPurchase.instance.restorePurchases();
  }

  /// Test-only: reset the singleton state.
  @visibleForTesting
  void resetForTest() {
    _advanced = false;
    _debugFreeUser = false;
    _debugTrialExpired = false;
    _trialStartedAtMs = null;
    _initialised = false;
  }

  /// Test-only: force the trial start time.
  @visibleForTesting
  void setTrialStartedAtForTest(DateTime? at) {
    _trialStartedAtMs = at?.millisecondsSinceEpoch;
  }
}

/// Gate-result enum: not required (not gated), available (free), paywall needed.
enum GateResult { notRequired, available, paywallNeeded }

/// Check if a gated feature is available.
///
/// [gateEnabled] — whether this feature is gated (all 7 are gated).
/// [advanced] — Entitlements.instance.isEntitled (paying OR in-trial).
/// [paywallActive] — Entitlements.instance.effectivePaywallEnabled.
GateResult checkGate({
  required bool gateEnabled,
  required bool advanced,
  required bool paywallActive,
}) {
  if (!gateEnabled || !paywallActive) return GateResult.notRequired;
  if (advanced) return GateResult.available;
  return GateResult.paywallNeeded;
}