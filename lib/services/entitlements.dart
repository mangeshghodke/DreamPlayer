import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
// Implementation imports: Apple's unfinished-transaction APIs are exposed by
// the StoreKit plugin wrappers rather than its public package exports.
// ignore: implementation_imports
import 'package:in_app_purchase_storekit/src/store_kit_2_wrappers/sk2_transaction_wrapper.dart' show SK2Transaction;
// ignore: implementation_imports
import 'package:in_app_purchase_storekit/src/store_kit_wrappers/sk_payment_queue_wrapper.dart' show SKPaymentQueueWrapper;
// ignore: implementation_imports
import 'package:in_app_purchase_storekit/src/store_kit_wrappers/sk_payment_transaction_wrappers.dart' show SKPaymentTransactionStateWrapper;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/iap_logger.dart';
import 'package:dream_player/services/trial_store.dart';

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

  /// True only after buyNonConsumable() has actually been called and returned.
  /// Prevents orphaned pending transactions from being accepted before the
  /// user taps a product (they arrive through purchaseStream instantly).
  bool _buyInitiated = false;

  /// The product ID of the active purchase (null = not purchased, only trial).
  String? _activeProductId;

  /// The product ID expected from an in-flight purchase (null when idle).
  String? _expectedProductId;

  /// Transaction ids finished by the unfinished-transaction sweep.
  ///
  /// StoreKit can deliver a transaction we just finished through the purchase
  /// stream — an Ask to Buy request that was still pending, for instance.
  /// Such a transaction was never completed, so it must NOT grant an
  /// entitlement (the sweep declined it). The ids are remembered here so the
  /// stream handler can tell those apart from a real re-delivery of a
  /// purchase the customer actually made.
  final Set<String> _sweptTransactionIds = <String>{};

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

  /// Completes once the first entitlement read has finished.
  ///
  /// The gates await this before deciding, so a subscriber is never shown the
  /// paywall during the first seconds after launch: the StoreKit query is
  /// asynchronous, and without this the gate would read `_advanced == false`
  /// and put the paywall in front of a paying user.
  final Completer<void> _ready = Completer<void>();

  /// Waits for the first entitlement read — bounded, so a slow or missing
  /// StoreKit can never block a gate. On timeout the gate simply uses the
  /// current state.
  Future<void> awaitReady() async {
    if (_ready.isCompleted) return;
    // Nothing is going to complete it (init() was never called) — waiting
    // would only stall the gate.
    if (!_initialised) return;
    try {
      await _ready.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      IapLog.instance.log('ENTITLE', 'awaitReady: timed out, using current state');
    }
  }

  /// Call once at app start.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      _debugFreeUser = prefs.getBool(_kDebugFreeUser) ?? false;
      _debugTrialExpired = prefs.getBool(_kDebugTrialExpired) ?? false;
    } catch (_) {}

    await _loadTrialStart();

    IapLog.instance.log('INIT', 'debugFreeUser=$_debugFreeUser, debugTrialExpired=$_debugTrialExpired, trialStartedAt=$_trialStartedAtMs, isAdvanced=$isAdvanced, isEntitled=$isEntitled');

    // Apple's guidance for StoreKit 2 (Transaction.updates):
    //   "Create a Task to iterate through the transactions from the listener
    //    as soon as your app launches. ... Without the updates listener to
    //    listen for these transactions, your app may miss them."
    //
    // StoreKit re-delivers the purchase history after an install, an app
    // update or a reinstall ("the app automatically has all transactions
    // available to it upon initial launch"), and for purchases completed on
    // another device. The listener has to be running BEFORE that happens or
    // the plan never comes back on its own — the user would have to tap
    // Restore Purchases after every update, which is exactly the complaint
    // this fixes.
    if (paywallEnabled) {
      startPurchaseListener();
      // Re-read what the customer already owns. Without this an app update
      // locks out existing subscribers until they tap Restore Purchases.
      await refreshEntitlements();
    }
    if (!_ready.isCompleted) _ready.complete();
  }

  /// Resolve the trial start time from both stores.
  ///
  /// SharedPreferences is read first so an existing install keeps the value it
  /// already has (and is backfilled into the Keychain so a later reinstall is
  /// covered). When SharedPreferences is empty — a fresh install, or a
  /// reinstall after the app was deleted — the Keychain is consulted, which is
  /// what makes the trial *resume* instead of restarting at day 0.
  Future<void> _loadTrialStart() async {
    int? fromPrefs;
    try {
      final prefs = await SharedPreferences.getInstance();
      fromPrefs = prefs.getInt(_kTrialStartedAt);
    } catch (_) {}
    if (fromPrefs != null && fromPrefs > 0) {
      _trialStartedAtMs = fromPrefs;
      // Migration: an install that predates the Keychain store. Backfill it so
      // deleting + reinstalling the app doesn't hand out a second trial.
      await TrialStore.instance.writeStartMs(fromPrefs);
      return;
    }
    final fromKeychain = await TrialStore.instance.readStartMs();
    if (fromKeychain != null) {
      _trialStartedAtMs = fromKeychain;
      IapLog.instance.log('TRIAL', 'restored from Keychain: $fromKeychain');
      // Mirror back into prefs so the value is present even if a future build
      // ever drops the Keychain read.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_kTrialStartedAt, fromKeychain);
      } catch (_) {}
    }
  }

  StreamSubscription<List<PurchaseDetails>>? purchaseSub;

  /// The product IDs we sell. Anything else in the transaction history is
  /// ignored when re-deriving entitlements.
  static const Set<String> _productIds = {
    'dp_premium_monthly_2026',
    'dp_premium_yearly_2026',
    'dp_premium_lifetime_2026',
  };

  /// Pure: does this transaction prove the user is entitled *right now*?
  ///
  /// [expirationMs] null means a non-consumable (the lifetime unlock), which
  /// never expires. A subscription is entitled until its expiry passes. A
  /// revoked transaction (refund, or family-sharing revoked) never counts,
  /// which is why the revocation check comes before the expiry check.
  @visibleForTesting
  static bool isEntitledTransaction({
    required String productId,
    required int? expirationMs,
    required int? revocationMs,
    int? nowMs,
  }) {
    if (!_productIds.contains(productId)) return false;
    if (revocationMs != null) return false;
    if (expirationMs == null) return true;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return expirationMs > now;
  }

  /// StoreKit returns dates as ISO-8601 strings in `jsonRepresentation` but as
  /// millisecond strings on the wrapper, so accept either.
  static int? _parseEpochMs(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final s = value.trim();
      if (s.isEmpty) return null;
      final asInt = int.tryParse(s);
      if (asInt != null) return asInt;
      return DateTime.tryParse(s)?.millisecondsSinceEpoch;
    }
    return null;
  }

  /// The entitlement facts carried by a purchase-stream event.
  ///
  /// The plugin puts StoreKit's canonical `jsonRepresentation` into
  /// `verificationData.localVerificationData` — the same payload the history
  /// query returns — so a stream event can be judged by exactly the same
  /// product/expiry/revocation rules as a history read.
  ///
  /// Returns null when the payload is missing or unreadable; the caller then
  /// falls back to the "the user just tapped Buy" heuristic.
  static ({String productId, int? expirationMs, int? revocationMs})?
      _entitlementFromDetails(PurchaseDetails p) {
    final raw = p.verificationData.localVerificationData;
    if (raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final productId =
          (json['productID'] ?? json['productId'] ?? p.productID).toString();
      return (
        productId: productId,
        expirationMs: _parseEpochMs(json['expirationDate']),
        revocationMs: _parseEpochMs(json['revocationDate']),
      );
    } catch (_) {
      return null;
    }
  }

  /// Re-derive entitlement from the customer's existing StoreKit purchases.
  ///
  /// Called at app start, and again after an explicit Restore Purchases.
  /// Without this, a customer who already paid is locked out after an app
  /// update: the app boots with `_advanced == false` because nothing ever asks
  /// StoreKit what the user already owns, and the only way back in is tapping
  /// Restore Purchases by hand. That is the bug this fixes.
  ///
  /// Reads `Transaction.all` (a plain query that creates no transactions and
  /// does not touch the payment queue) and keeps any of our products that is
  /// neither revoked nor expired.
  ///
  /// [force] re-reads even when this session is already entitled, so a restore
  /// can confirm the purchase instead of trusting a stream event.
  Future<void> refreshEntitlements({bool force = false}) async {
    if (defaultTargetPlatform == TargetPlatform.android) return;
    if (!paywallEnabled && !_debugFreeUser) return;
    if (_advanced && !force) return; // already entitled this session
    try {
      final scan = await _scanHistory();
      final entitledProduct = scan.entitledProduct;
      if (entitledProduct == null) {
        IapLog.instance.log(
          'ENTITLE',
          'no active purchase found in ${scan.count} transaction(s) '
          '(store ${scan.seen.isEmpty ? 'empty' : scan.seen.join(', ')})',
        );
        return;
      }
      _advanced = true;
      _activeProductId = entitledProduct;
      _purchaseFailed = false;
      _purchaseCanceled = false;
      IapLog.instance.log('ENTITLE', 'restored existing purchase: $entitledProduct');
      notifyListeners();
    } catch (e) {
      IapLog.instance.log('ENTITLE', 'refreshEntitlements ERROR: $e');
    }
  }

  /// Read the whole transaction history and decide what it entitles.
  ///
  /// `environment` is "Sandbox" for TestFlight/development and "Production"
  /// for the App Store. The two have separate transaction histories, which is
  /// why a purchase made in the App Store is invisible in a TestFlight build
  /// (and vice-versa). Every transaction is logged so a "no previous purchase
  /// found" report can be answered from the log instead of guessed at: zero
  /// transactions and a Sandbox entry mean an environment mismatch, not a
  /// broken restore.
  Future<({String? entitledProduct, int count, List<String> seen})>
      _scanHistory() async {
    final all = await SK2Transaction.transactions();
    String? entitledProduct;
    final seen = <String>[];
    for (final t in all) {
      var productId = t.productId;
      int? expirationMs = _parseEpochMs(t.expirationDate);
      int? revocationMs;
      var environment = 'unknown';

      // jsonRepresentation is the canonical StoreKit 2 payload and carries
      // revocationDate / productID; the wrapper omits revocation entirely.
      final raw = t.jsonRepresentation;
      if (raw != null && raw.isNotEmpty) {
        try {
          final json = jsonDecode(raw);
          if (json is Map<String, dynamic>) {
            productId = (json['productID'] ?? json['productId'] ?? productId)
                as String;
            expirationMs =
                _parseEpochMs(json['expirationDate']) ?? expirationMs;
            revocationMs = _parseEpochMs(json['revocationDate']);
            environment = (json['environment'] ?? 'unknown').toString();
          }
        } catch (_) {
          // Keep the wrapper-derived values; expiry/revocation fall back to
          // the conservative reading below.
        }
      }
      seen.add('$productId/$environment');
      IapLog.instance.log(
        'ENTITLE',
        'tx product=$productId env=$environment '
        'expiration=$expirationMs revocation=$revocationMs',
      );

      if (isEntitledTransaction(
        productId: productId,
        expirationMs: expirationMs,
        revocationMs: revocationMs,
      )) {
        entitledProduct ??= productId;
      }
    }
    return (entitledProduct: entitledProduct, count: all.length, seen: seen);
  }

  /// Pure: should a re-scan of the transaction history REVOKE the entitlement?
  ///
  /// [transactionCount] is how many transactions the account has,
  /// [entitledProduct] the product (if any) that still entitles the user.
  ///
  /// The rule is deliberately CONSERVATIVE: the entitlement is only revoked
  /// when the account still has transactions but none of them entitle the user
  /// any more (a lapsed subscription, a refunded lifetime). An EMPTY history
  /// is ambiguous — StoreKit may simply not have refreshed yet — so it never
  /// revokes an entitlement on that basis. Locking a paying customer out over
  /// a transient empty cache is a far worse failure than letting a lapsed
  /// subscriber keep the feature until the next launch.
  @visibleForTesting
  static bool revalidateShouldRevoke({
    required int transactionCount,
    required String? entitledProduct,
  }) =>
      transactionCount > 0 && entitledProduct == null;

  /// Re-check the entitlement when the app comes back to the foreground.
  ///
  /// A subscription that lapsed while the app was in the background must stop
  /// being premium, and a purchase made elsewhere (the Apple Store tab, a
  /// redemption code) must start being premium — without either needing a
  /// restart.
  Future<void> revalidate() async {
    if (defaultTargetPlatform == TargetPlatform.android) return;
    if (!paywallEnabled && !_debugFreeUser) return;
    try {
      final scan = await _scanHistory();
      final entitledProduct = scan.entitledProduct;
      if (entitledProduct != null) {
        if (!_advanced || _activeProductId != entitledProduct) {
          _advanced = true;
          _activeProductId = entitledProduct;
          IapLog.instance.log('ENTITLE', 'revalidate: entitled via $entitledProduct');
          notifyListeners();
        }
        return;
      }
      if (revalidateShouldRevoke(
        transactionCount: scan.count,
        entitledProduct: entitledProduct,
      ) &&
          _advanced) {
        // The account has transactions, but none of them entitle the user any
        // more — the subscription lapsed or the purchase was refunded.
        IapLog.instance.log(
          'ENTITLE',
          'revalidate: ${scan.count} transaction(s) but none entitled '
          '(${scan.seen.join(', ')}) → revoking entitlement',
        );
        _advanced = false;
        _activeProductId = null;
        notifyListeners();
        return;
      }
      IapLog.instance.log(
        'ENTITLE',
        'revalidate: no transactions — keeping the current entitlement',
      );
    } catch (e) {
      IapLog.instance.log('ENTITLE', 'revalidate ERROR: $e');
    }
  }

  /// Start listening to the StoreKit purchase stream.
  ///
  /// Called at app launch (so StoreKit's transaction re-delivery after an
  /// install/update/reinstall is never missed) and again when the paywall
  /// opens. Idempotent.
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
    // Sweep unfinished transactions right away (fire-and-forget — the
    // paywall's product loading covers the wait). Per Apple's docs the
    // updates listener receives unfinished transactions once at launch;
    // finishing them keeps the queue clean so no later purchase can
    // short-circuit the Apple confirmation sheet.
    // The RELIABLE sweep (direct SK2 unfinished list) runs again before
    // every buyNonConsumable — see sweepUnfinishedTransactions().
    unawaited(sweepUnfinishedTransactions());
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

  /// Finish ALL unfinished StoreKit transactions directly, before a purchase
  /// attempt.
  ///
  /// Per Apple's docs (Transaction.unfinished / Transaction.finish):
  /// unfinished transactions short-circuit Product.purchase() — StoreKit
  /// returns the existing unfinished transaction instead of displaying the
  /// confirmation sheet. Finishing them first guarantees the Apple sheet
  /// appears for every buy tap. This is a direct LIST query (not the
  /// purchaseStream), so it has no stream-timing race.
  ///
  /// StoreKit 2 and StoreKit 1 can each retain a queue entry. The plugin uses
  /// StoreKit 2 for purchases, but its native StoreKit 1 handler still owns a
  /// separate SKPaymentQueue; query and drain both queues before every buy.
  ///
  /// Returns the number of transactions finished.
  Future<int> sweepUnfinishedTransactions() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return 0;
    var finished = 0;
    try {
      try {
        final unfinished = await SK2Transaction.unfinishedTransactions();
        finished += await _finishSk2Transactions(unfinished);
      } catch (e) {
        IapLog.instance.log('SWEEP', 'SK2 unfinishedTransactions() ERROR: $e');
      }

      try {
        final queue = SKPaymentQueueWrapper();
        final queued = await queue.transactions();
        final unfinished = queued
            .where((transaction) =>
                transaction.transactionState !=
                SKPaymentTransactionStateWrapper.purchasing)
            .toList();
        if (unfinished.isEmpty) {
          IapLog.instance.log('SWEEP', 'SK1 queue: no finishable transactions');
        } else {
          IapLog.instance.log(
            'SWEEP',
            'SK1 queue: finishing ${unfinished.length} transaction(s): '
            '${unfinished.map((transaction) => transaction.payment.productIdentifier).join(', ')}',
          );
          for (final transaction in unfinished) {
            try {
              await queue.finishTransaction(transaction);
              finished++;
              IapLog.instance.log(
                'SWEEP',
                'SK1 finished product=${transaction.payment.productIdentifier} '
                'state=${transaction.transactionState} '
                'id=${transaction.transactionIdentifier ?? 'unknown'}',
              );
            } catch (e) {
              IapLog.instance.log(
                'SWEEP',
                'SK1 finish product=${transaction.payment.productIdentifier} ERROR: $e',
              );
            }
          }
        }
      } catch (e) {
        IapLog.instance.log('SWEEP', 'SK1 transactions() ERROR: $e');
      }
      return finished;
    } finally {
      if (finished == 0) {
        IapLog.instance.log('SWEEP', 'no unfinished transactions finished');
      }
    }
  }

  Future<int> _finishSk2Transactions(List<SK2Transaction> unfinished) async {
    if (unfinished.isEmpty) {
      IapLog.instance.log('SWEEP', 'SK2: no unfinished transactions');
      return 0;
    }
    IapLog.instance.log(
      'SWEEP',
      'SK2: finishing ${unfinished.length} unfinished transaction(s): '
      '${unfinished.map((transaction) => transaction.productId).join(', ')}',
    );
    var finished = 0;
    for (final transaction in unfinished) {
      final id = int.tryParse(transaction.id);
      if (id == null) {
        IapLog.instance.log(
          'SWEEP',
          'SK2 SKIP transaction with unparseable id: '
          '${transaction.id} (${transaction.productId})',
        );
        continue;
      }
      try {
        await SK2Transaction.finish(id);
        finished++;
        _sweptTransactionIds.add(transaction.id);
        IapLog.instance.log(
          'SWEEP',
          'SK2 finished id=$id product=${transaction.productId}',
        );
      } catch (e) {
        IapLog.instance.log('SWEEP', 'SK2 finish id=$id ERROR: $e');
      }
    }
    return finished;
  }

  /// Persist the trial start time to BOTH stores.
  ///
  /// SharedPreferences is the app-container copy (fast, always writable);
  /// the iOS Keychain is the copy that survives app deletion, which is what
  /// stops the delete-and-reinstall free-trial loop.
  Future<void> _persistTrialStart(int ms) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kTrialStartedAt, ms);
    } catch (_) {}
    await TrialStore.instance.writeStartMs(ms);
  }

  Future<void> _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    IapLog.instance.log('PURCHASE_STREAM', 'received ${purchases.length} purchase(s)');
    for (final p in purchases) {
      IapLog.instance.log('PURCHASE_UPDATE', 'status=${p.status}, productID=${p.productID}, pendingComplete=${p.pendingCompletePurchase}, verification=${p.verificationData}');

      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        // Judge the transaction by its CONTENT, not by whether the user just
        // tapped Buy. StoreKit re-delivers the purchase history after an
        // install, an app update or a reinstall, and for purchases completed
        // on another device; those transactions are finished (not pending)
        // and carry the same product/expiry/revocation facts as any other.
        // Requiring `_buyInitiated` here meant a returning subscriber's plan
        // was dropped on the floor and only came back after tapping Restore
        // Purchases.
        //
        // What is still rejected: a transaction for a product we do not sell,
        // a refunded/revoked one, and an expired subscription — all of them
        // fail `isEntitledTransaction`. Only when the payload cannot be read
        // at all does the old "the user just tapped Buy" heuristic apply.
        final tx = _entitlementFromDetails(p);
        final initiated = _buyInitiated || _restorePending;
        final productMatches =
            _expectedProductId == null || p.productID == _expectedProductId;
        final swept = p.purchaseID != null &&
            _sweptTransactionIds.contains(p.purchaseID);
        final accept = !swept &&
            (tx != null
                ? isEntitledTransaction(
                    productId: tx.productId,
                    expirationMs: tx.expirationMs,
                    revocationMs: tx.revocationMs,
                  )
                : (initiated && productMatches));

        if (!accept) {
          IapLog.instance.log(
            'PURCHASE_UPDATE',
            'REJECTED ${p.status}: productID=${p.productID}, '
            'parsed=${tx != null}, initiated=$initiated, swept=$swept, '
            'expected=$_expectedProductId',
          );
          if (p.pendingCompletePurchase) {
            await InAppPurchase.instance.completePurchase(p);
            IapLog.instance.log(
              'PURCHASE_UPDATE',
              'completePurchase done for rejected: ${p.productID}',
            );
          }
          continue;
        }

        IapLog.instance.log(
          'PURCHASE_UPDATE',
          'ACCEPTED ${p.status}: productID=${p.productID}, '
          'source=${initiated ? 'user action' : 'store re-delivery'}',
        );
        _advanced = true;
        _activeProductId = tx?.productId ?? p.productID;
        _expectedProductId = null;
        _restorePending = false;
        _buyInitiated = false;
        _debugFreeUser = false;
        _purchaseFailed = false;
        _purchaseCanceled = false;
        if (p.pendingCompletePurchase) {
          await InAppPurchase.instance.completePurchase(p);
          IapLog.instance.log('PURCHASE_UPDATE', 'completePurchase done for accepted: ${p.productID}');
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
          await InAppPurchase.instance.completePurchase(p);
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
  ///
  /// Restores rather than restarts when a start time already exists (from
  /// SharedPreferences OR the iOS Keychain) — this is the guard that closes
  /// the delete-and-reinstall loop: after a reinstall the Keychain still holds
  /// the original timestamp, so the remaining days are honored instead of a
  /// fresh 7 days being handed out.
  Future<void> startTrial() async {
    if (_trialStartedAtMs == null) {
      // init() normally populates this from both stores, but the paywall can
      // be reached before init() settles. Re-check the Keychain here so a
      // restore is never overwritten with "now".
      final restored = await TrialStore.instance.readStartMs();
      if (restored != null) {
        _trialStartedAtMs = restored;
        await _persistTrialStart(restored);
        notifyListeners();
        return;
      }
      _trialStartedAtMs = DateTime.now().millisecondsSinceEpoch;
      await _persistTrialStart(_trialStartedAtMs!);
      notifyListeners();
      return;
    }
    // Already started. Re-persist anyway (idempotent) so an install that
    // predates the Keychain store gets its start time written there — without
    // this, a pre-Keychain user would keep getting a fresh trial on every
    // reinstall because nothing ever backfills the surviving store.
    await _persistTrialStart(_trialStartedAtMs!);
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

  /// Mark that buyNonConsumable() has actually been called and returned.
  /// Only after this flag is true will _onPurchaseUpdate accept `purchased`
  /// status — preventing orphaned pending transactions from being accepted
  /// before the user taps a product.
  void markBuyInitiated() {
    _buyInitiated = true;
    IapLog.instance.log('BUY', 'markBuyInitiated: _buyInitiated=true');
  }

  /// Clear the buy-initiated flag (call when purchase completes, errors, or cleans up).
  void clearBuyInitiated() {
    _buyInitiated = false;
  }

  /// Buy a product. Returns true if the transaction initiated successfully.
  Future<bool> buy(String productId) async {
    IapLog.instance.log('BUY', 'called for productId=$productId, platform=$defaultTargetPlatform, debugFreeUser=$_debugFreeUser');
    if (defaultTargetPlatform == TargetPlatform.android && !_debugFreeUser) {
      IapLog.instance.log('BUY', 'REJECTED: android non-debug');
      return false;
    }
    // A new attempt starts from a clean slate: the previous attempt's
    // failure/cancel flags must not be mistaken for this one's outcome.
    _purchaseFailed = false;
    _purchaseCanceled = false;
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
    // Ask the App Store first. The plugin's StoreKit 2 restore only enumerates
    // the local cache, which can be empty after a reinstall even though the
    // account owns the product; AppStore.sync() is what re-fetches it (and
    // prompts for the owning Apple ID if the device is signed in with a
    // different one).
    final synced = await TrialStore.instance.syncPurchasesWithAppStore();
    IapLog.instance.log('RESTORE', 'AppStore.sync() -> $synced');
    IapLog.instance.log('RESTORE', 'calling InAppPurchase.instance.restorePurchases()');
    try {
      await InAppPurchase.instance.restorePurchases();
      IapLog.instance.log('RESTORE', 'restorePurchases() completed');
      // The plugin's StoreKit 2 restore enumerates `currentEntitlements` and
      // delivers them through the purchase stream; it never calls
      // `AppStore.sync()`. Re-derive from `Transaction.all` as well so a
      // restore does not depend on a stream event landing inside the paywall's
      // three-second window. This is a read-only query — it cannot grant an
      // entitlement that StoreKit does not already report.
      await refreshEntitlements(force: true);
      IapLog.instance.log(
        'RESTORE',
        'post-restore refresh: isAdvanced=$_advanced '
        'active=${_activeProductId ?? 'none'}',
      );
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
    _buyInitiated = false;
    _purchaseFailed = false;
    _purchaseCanceled = false;
    _initialised = false;
    _sweptTransactionIds.clear();
    purchaseSub?.cancel();
    purchaseSub = null;
    if (!_ready.isCompleted) _ready.complete();
    TrialStore.resetProbeForTest();
  }

  /// Test-only: force the trial start time.
  @visibleForTesting
  void setTrialStartedAtForTest(DateTime? at) {
    _trialStartedAtMs = at?.millisecondsSinceEpoch;
  }

  /// Test-only: the raw StoreKit entitlement — WITHOUT the Android immunity
  /// and without the debug override.
  ///
  /// `advanced` / `isAdvanced` are deliberately unusable for asserting what
  /// StoreKit said: on Android `advanced` is unconditionally true, so the
  /// only way to observe the real state is this raw flag.
  @visibleForTesting
  bool get storeKitEntitled => _advanced;

  /// Test-only: remember a transaction id as "finished by the launch sweep".
  @visibleForTesting
  void markSweptTransactionForTest(String id) => _sweptTransactionIds.add(id);

  /// Test-only: feed a synthetic purchase-stream event into the handler.
  ///
  /// The real events come from StoreKit's `Transaction.updates`; this is the
  /// same code path with a hand-built payload, so the acceptance rules can be
  /// pinned without a device.
  @visibleForTesting
  Future<void> handlePurchaseUpdateForTest(List<PurchaseDetails> purchases) =>
      _onPurchaseUpdate(purchases);
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

/// Pure decision: may a persisted DSP setting stay ON?
///
/// [saved] — the stored value (for the bass level, `level > 0`).
/// [advanced] — Entitlements.instance.isEntitled.
/// [paywallActive] — Entitlements.instance.effectivePaywallEnabled.
///
/// Mirrors `spatialAudioMayBeEnabled`: the gate is on turning a premium
/// feature ON, so a saved ON survives only while the user is entitled.
bool dspSettingMayStayEnabled({
  required bool saved,
  required bool advanced,
  required bool paywallActive,
}) {
  if (!saved) return false;
  if (!paywallActive) return true;
  return advanced;
}

/// Correction for a persisted iOS DSP setting — night mode, or a bass level
/// stored as `saved > 0` — the exact shape
/// `SpatialAudioStore.effectiveEnabled` applies to spatial audio.
///
/// The value a user turned ON stays on across restarts while they are
/// entitled (paying or in trial); once the entitlement lapses a stale ON is
/// forced back to OFF, so a premium feature can never keep working for free
/// from the stored pref alone. Android never corrects: the paywall is
/// iOS-only and `Entitlements` hard-rewards `advanced` there, so the
/// platform check alone keeps Android immune regardless of store state.
bool effectiveDspSetting(bool saved) {
  if (!saved || defaultTargetPlatform != TargetPlatform.iOS) return saved;
  final ent = Entitlements.instance;
  return dspSettingMayStayEnabled(
    saved: saved,
    advanced: ent.isEntitled,
    paywallActive: ent.effectivePaywallEnabled,
  );
}
