import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/iap_logger.dart';

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
  bool _purchaseFailed = false;
  bool _purchaseCanceled = false;

  /// The product ID of the active purchase (null = not purchased, only trial).
  String? _activeProductId;

  /// The product ID expected from an in-flight purchase (null when idle).
  String? _expectedProductId;

  /// True while an explicit restorePurchases() is in flight.
  bool _restorePending = false;

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
    final rem = trialDuration.inMilliseconds -
        (DateTime.now().millisecondsSinceEpoch - start);
    return Duration(milliseconds: rem < 0 ? 0 : rem);
  }

  /// When the trial was started (null if never started).
  DateTime? get trialStarted {
    final ms = _trialStartedAtMs;
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Whether the trial was ever started (active or expired).
  bool get trialStartedEver => _trialStartedAtMs != null;

  /// Effective "advanced" that respects the debug override.
  bool get isAdvanced => _debugFreeUser ? false : advanced;

  /// Effective entitlement for gates: a paying user OR an in-trial user.
  /// Trial users pass every gate; after the trial the paywall engages.
  bool get isEntitled => isAdvanced || trialActive;

  /// Effective "paywall enabled" that respects the debug override.
  /// On Android paywallEnabled is false by default, but when debugFreeUser
  /// is true we override it to true so gates actually fire for testing.
  /// kDebugMode gate: the debug override only takes effect in debug builds,
  /// so a persisted _debugFreeUser flag can never leak the paywall into a
  /// release APK.
  bool get effectivePaywallEnabled =>
      paywallEnabled || (_debugFreeUser && kDebugMode && defaultTargetPlatform == TargetPlatform.android);

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
    } catch (_) {}

    // Load trial start time from SharedPreferences (clears on app delete).
    try {
      final prefs = await SharedPreferences.getInstance();
      _trialStartedAtMs = prefs.getInt(_kTrialStartedAt);
    } catch (_) {}

    IapLog.instance.log('INIT', 'debugFreeUser=$_debugFreeUser, debugTrialExpired=$_debugTrialExpired, trialStartedAt=$_trialStartedAtMs, isAdvanced=$isAdvanced, isEntitled=$isEntitled');

    // Drain any orphaned pending transactions left from previous installs/tests.
    // StoreKit re-delivers them on the next buyNonConsumable call, which causes
    // "instantly Active" (no Apple sheet) and storekit_duplicate_product_object.
    if (defaultTargetPlatform == TargetPlatform.iOS && (paywallEnabled || _debugFreeUser)) {
      _drainPendingTransactions();
    }
  }

  /// Restore purchases then complete every pending transaction to clear the queue.
  Future<void> _drainPendingTransactions() async {
    try {
      IapLog.instance.log('DRAIN', 'starting — restoring purchases to find orphans');
      // Listen once, collect everything, complete all.
      final completer = Completer<void>();
      late StreamSubscription<List<PurchaseDetails>> sub;
      sub = InAppPurchase.instance.purchaseStream.listen((purchases) {
        for (final p in purchases) {
          IapLog.instance.log('DRAIN', 'got: status=${p.status}, productID=${p.productID}, pendingComplete=${p.pendingCompletePurchase}');
          if (p.status == PurchaseStatus.purchased || p.status == PurchaseStatus.restored) {
            // Accept if it matches an active entitlement (sandbox re-delivers buys).
            if (p.productID == _activeProductId || p.productID == 'dp_premium_lifetime_2026' ||
                p.productID == 'dp_premium_monthly_2026' || p.productID == 'dp_premium_yearly_2026') {
              if (p.status == PurchaseStatus.purchased && p.pendingCompletePurchase) {
                IapLog.instance.log('DRAIN', 'completing orphan: ${p.productID}');
                InAppPurchase.instance.completePurchase(p);
              }
            } else if (p.pendingCompletePurchase) {
              IapLog.instance.log('DRAIN', 'completing unknown orphan: ${p.productID}');
              InAppPurchase.instance.completePurchase(p);
            }
          }
        }
        if (!completer.isCompleted) completer.complete();
      });
      await InAppPurchase.instance.restorePurchases();
      await completer.future.timeout(const Duration(seconds: 3));
      await sub.cancel();
      IapLog.instance.log('DRAIN', 'done');
    } catch (e) {
      IapLog.instance.log('DRAIN', 'error: $e');
    }
  }

  StreamSubscription<List<PurchaseDetails>>? purchaseSub;

  /// Start listening to StoreKit purchase stream (call when paywall opens).
  void startPurchaseListener() {
    if (purchaseSub != null) {
      IapLog.instance.log('LISTENER', 'already listening, skip');
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      IapLog.instance.log('LISTENER', 'android, skip');
      return;
    }
    if (!paywallEnabled && !_debugFreeUser) {
      IapLog.instance.log('LISTENER', 'paywall not enabled and not debug, skip');
      return;
    }
    purchaseSub =
        InAppPurchase.instance.purchaseStream.listen(_onPurchaseUpdate);
    IapLog.instance.log('LISTENER', 'started listening to purchaseStream');
  }

  /// Stop listening (call when paywall closes).
  void stopPurchaseListener() {
    purchaseSub?.cancel();
    purchaseSub = null;
    IapLog.instance.log('LISTENER', 'stopped listening');
  }

  Future<void> _persistTrialStart(int ms) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kTrialStartedAt, ms);
    } catch (_) {}
  }

  void _onPurchaseUpdate(List<PurchaseDetails> purchases) {
    IapLog.instance.log('PURCHASE_STREAM', 'received ${purchases.length} purchase(s)');
    for (final p in purchases) {
      IapLog.instance.log('PURCHASE_UPDATE', 'status=${p.status}, productID=${p.productID}, pendingComplete=${p.pendingCompletePurchase}, verification=${p.verificationData}');
      if (p.status == PurchaseStatus.purchased) {
        // New purchase — accept when user explicitly tapped a product
        // (expectedProductId set by _buy) and the transaction is fresh,
        // OR when a Restore is in flight (StoreKit may emit purchased
        // for an active subscription on restore).
        final isRestorePurchase = _restorePending;
        if (!isRestorePurchase &&
            (_expectedProductId == null || p.productID != _expectedProductId)) {
          IapLog.instance.log('PURCHASE_UPDATE', 'REJECTED purchased: isRestore=$isRestorePurchase, expected=$_expectedProductId, got=${p.productID}');
          if (p.pendingCompletePurchase) {
            InAppPurchase.instance.completePurchase(p);
          }
          continue;
        }
        // (Removed stale transactionDate check — it was rejecting
        // fresh Lifetime purchases as stale in sandbox, causing
        // ring → Purchase cancelled without sheet. The
        // expectedProductId gate already prevents auto-activation.)
        IapLog.instance.log('PURCHASE_UPDATE', 'ACCEPTED purchased: productID=${p.productID}, isRestore=$isRestorePurchase');
        _advanced = true;
        _activeProductId = p.productID;
        _expectedProductId = null;
        _restorePending = false;
        _debugFreeUser = false;
        _purchaseFailed = false;
        _purchaseCanceled = false;
        if (p.pendingCompletePurchase) {
          InAppPurchase.instance.completePurchase(p);
        }
        notifyListeners();
        return;
      }
      if (p.status == PurchaseStatus.restored) {
        // Restore — only accept when user explicitly tapped Restore.
        if (!_restorePending) {
          IapLog.instance.log('PURCHASE_UPDATE', 'REJECTED restored: _restorePending=false');
          if (p.pendingCompletePurchase) {
            InAppPurchase.instance.completePurchase(p);
          }
          continue;
        }
        IapLog.instance.log('PURCHASE_UPDATE', 'ACCEPTED restored: productID=${p.productID}');
        _advanced = true;
        _activeProductId = p.productID;
        _expectedProductId = null;
        _restorePending = false;
        _debugFreeUser = false;
        _purchaseFailed = false;
        _purchaseCanceled = false;
        if (p.pendingCompletePurchase) {
          InAppPurchase.instance.completePurchase(p);
        }
        notifyListeners();
        return;
      }
      if (p.status == PurchaseStatus.canceled) {
        IapLog.instance.log('PURCHASE_UPDATE', 'CANCELED: productID=${p.productID}');
        _purchaseCanceled = true;
        // Sandbox: StoreKit can fire canceled before purchased — don't
        // treat as terminal immediately; give purchased a short window.
        // Complete so StoreKit clears the transaction.
        if (p.pendingCompletePurchase) {
          InAppPurchase.instance.completePurchase(p);
        }
        notifyListeners();
        // Clear the flag shortly after so next purchase isn't polluted,
        // but keep it long enough for the paywall's completer to see it.
        Future<void>.delayed(const Duration(milliseconds: 800), () {
          _purchaseCanceled = false;
        });
        return;
      }
      if (p.status == PurchaseStatus.error) {
        IapLog.instance.log('PURCHASE_UPDATE', 'ERROR: productID=${p.productID}, error=${p.error}');
        _expectedProductId = null;
        _purchaseFailed = true;
        _purchaseCanceled = false;
        notifyListeners();
        return;
      }
    }
  }

  /// Toggle the debug "simulate free user" override.
  Future<void> setDebugFreeUser(bool value) async {
    _debugFreeUser = value;
    if (!value) _advanced = false; // reset to platform default (Android stays gated-true)
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDebugFreeUser, value);
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

  /// Start the 7-day free trial (called from the paywall "Start free trial" button).
  Future<void> startTrial() async {
    if (_trialStartedAtMs != null) return; // already started
    _trialStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    await _persistTrialStart(_trialStartedAtMs!);
    notifyListeners();
  }

  bool get purchaseFailed => _purchaseFailed;
  bool get purchaseCanceled => _purchaseCanceled;
  String? get activeProductId => _activeProductId;

  void resetPurchaseFailed() {
    _purchaseFailed = false;
    _purchaseCanceled = false;
    notifyListeners();
  }

  /// Set the expected product ID before launching a purchase.
  void setExpectedProduct(String productId) {
    _expectedProductId = productId;
  }

  /// Buy a product. Returns true if the transaction initiated successfully.
  Future<bool> buy(String productId) async {
    IapLog.instance.log('BUY', 'called for productId=$productId, platform=$defaultTargetPlatform, debugFreeUser=$_debugFreeUser');
    if (defaultTargetPlatform == TargetPlatform.android && !_debugFreeUser) {
      IapLog.instance.log('BUY', 'REJECTED: android non-debug');
      return false;
    }
    final available = await InAppPurchase.instance.isAvailable();
    IapLog.instance.log('BUY', 'isAvailable=$available');
    if (!available) return false;
    final details = await InAppPurchase.instance.queryProductDetails({productId});
    IapLog.instance.log('BUY', 'queryProductDetails: found=${details.productDetails.length}, ids=${details.productDetails.map((p) => p.id).toList()}');
    if (details.productDetails.isEmpty) return false;
    final param = PurchaseParam(productDetails: details.productDetails.first);
    final success = await InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
    IapLog.instance.log('BUY', 'buyNonConsumable returned: $success');
    return success;
  }

  /// Restore purchases — explicit user action only.
  Future<void> restorePurchases() async {
    IapLog.instance.log('RESTORE', 'called, platform=$defaultTargetPlatform');
    if (defaultTargetPlatform == TargetPlatform.android && !_debugFreeUser) {
      IapLog.instance.log('RESTORE', 'REJECTED: android non-debug');
      return;
    }
    _restorePending = true;
    _expectedProductId = null;
    IapLog.instance.log('RESTORE', 'calling InAppPurchase.instance.restorePurchases()');
    try {
      await InAppPurchase.instance.restorePurchases();
      IapLog.instance.log('RESTORE', 'restorePurchases() completed');
    } catch (e) {
      IapLog.instance.log('RESTORE', 'restorePurchases() ERROR: $e');
      _restorePending = false;
      rethrow;
    }
    // Clear pending flag after a short window if nothing was restored.
    Future<void>.delayed(const Duration(seconds: 5), () {
      IapLog.instance.log('RESTORE', 'clearing _restorePending after 5s');
      _restorePending = false;
    });
  }

  /// Test-only: reset the singleton state.
  @visibleForTesting
  void resetForTest() {
    _advanced = false;
    _debugFreeUser = false;
    _debugTrialExpired = false;
    _trialStartedAtMs = null;
    _activeProductId = null;
    _expectedProductId = null;
    _restorePending = false;
    _purchaseFailed = false;
    _purchaseCanceled = false;
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