import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/screens/paywall_sheet.dart';
import 'package:dream_player/services/entitlements.dart';

/// A purchase-stream event shaped like the ones the StoreKit 2 plugin
/// delivers: the canonical `jsonRepresentation` sits in
/// `verificationData.localVerificationData`.
PurchaseDetails _event({
  required String productId,
  required String status,
  String? expirationDate,
  String? revocationDate,
  String? environment = 'Sandbox',
  bool includeJson = true,
  String? purchaseId,
}) {
  final json = jsonEncode({
    'productID': productId,
    'environment': environment,
    'expirationDate': ?expirationDate,
    'revocationDate': ?revocationDate,
  });  return PurchaseDetails(
    productID: productId,
    verificationData: PurchaseVerificationData(
      localVerificationData: includeJson ? json : '',
      serverVerificationData: '',
      source: 'storekit',
    ),
    transactionDate: '1700000000000',
    status: status == 'purchased'
        ? PurchaseStatus.purchased
        : status == 'restored'
            ? PurchaseStatus.restored
            : PurchaseStatus.error,
    purchaseID: purchaseId,
  );
}

void main() {
  setUp(() {
    // Without the mock, SharedPreferences awaits a platform channel that
    // never answers in a test.
    SharedPreferences.setMockInitialValues({});
    Entitlements.instance.resetForTest();
  });

  group('StoreKit transaction re-delivery (update / reinstall)', () {
    test('a finished, valid transaction is accepted without a Buy tap', () async {
      // This is the case that used to be dropped: StoreKit re-delivers the
      // purchase history after an install/update/reinstall, and the old code
      // required `_buyInitiated` — so the plan only came back after the user
      // tapped Restore Purchases.
      final e = Entitlements.instance;
      await e.handlePurchaseUpdateForTest([
        _event(
          productId: 'dp_premium_lifetime_2026',
          status: 'purchased',
        ),
      ]);
      expect(e.storeKitEntitled, isTrue);
      expect(e.activeProductId, 'dp_premium_lifetime_2026');
    });

    test('a restored transaction is accepted without a Restore tap', () async {
      final e = Entitlements.instance;
      await e.handlePurchaseUpdateForTest([
        _event(productId: 'dp_premium_yearly_2026', status: 'restored'),
      ]);
      expect(e.storeKitEntitled, isTrue);
    });

    test('a subscription that is still running is accepted', () async {
      final e = Entitlements.instance;
      await e.handlePurchaseUpdateForTest([
        _event(
          productId: 'dp_premium_monthly_2026',
          status: 'purchased',
          expirationDate:
              DateTime.now().add(const Duration(days: 10)).toIso8601String(),
        ),
      ]);
      expect(e.storeKitEntitled, isTrue);
    });

    test('an EXPIRED subscription is rejected', () async {
      final e = Entitlements.instance;
      await e.handlePurchaseUpdateForTest([
        _event(
          productId: 'dp_premium_monthly_2026',
          status: 'purchased',
          expirationDate:
              DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
        ),
      ]);
      expect(e.storeKitEntitled, isFalse);
    });

    test('a REFUNDED (revoked) transaction is rejected', () async {
      final e = Entitlements.instance;
      await e.handlePurchaseUpdateForTest([
        _event(
          productId: 'dp_premium_lifetime_2026',
          status: 'purchased',
          revocationDate:
              DateTime.now().subtract(const Duration(days: 2)).toIso8601String(),
        ),
      ]);
      expect(e.storeKitEntitled, isFalse);
    });

    test('a transaction for a product we do not sell is rejected', () async {
      final e = Entitlements.instance;
      await e.handlePurchaseUpdateForTest([
        _event(productId: 'someone_elses_product', status: 'purchased'),
      ]);
      expect(e.storeKitEntitled, isFalse);
    });

    test('an unreadable payload falls back to the Buy-tap heuristic', () async {
      // No JSON at all: the only remaining evidence is that the user just
      // tapped Buy, so the transaction must NOT be accepted on its own.
      final e = Entitlements.instance;
      await e.handlePurchaseUpdateForTest([
        _event(
          productId: 'dp_premium_lifetime_2026',
          status: 'purchased',
          includeJson: false,
        ),
      ]);
      expect(e.storeKitEntitled, isFalse);

      // …and with a Buy in flight it IS accepted.
      e.setExpectedProduct('dp_premium_lifetime_2026');
      e.markBuyInitiated();
      await e.handlePurchaseUpdateForTest([
        _event(
          productId: 'dp_premium_lifetime_2026',
          status: 'purchased',
          includeJson: false,
        ),
      ]);
      expect(e.storeKitEntitled, isTrue);
    });

    test('a transaction the launch sweep already finished is rejected', () async {
      // An Ask to Buy request that was still pending when the app launched:
      // the sweep finished (declined) it, so the re-delivery must not grant
      // an entitlement. The history scan is what decides what they own.
      final e = Entitlements.instance;
      e.markSweptTransactionForTest('4242');
      await e.handlePurchaseUpdateForTest([
        _event(
          productId: 'dp_premium_lifetime_2026',
          status: 'purchased',
          purchaseId: '4242',
        ),
      ]);
      expect(e.storeKitEntitled, isFalse);
    });
  });

  group('revalidate (foreground)', () {
    test('an empty history never revokes the entitlement', () {
      // StoreKit may simply not have refreshed yet — locking a paying
      // customer out over a transient empty cache is the worse failure.
      expect(
        Entitlements.revalidateShouldRevoke(
          transactionCount: 0,
          entitledProduct: null,
        ),
        isFalse,
      );
    });

    test('transactions that no longer entitle the user revoke it', () {
      // A lapsed subscription or a refunded lifetime.
      expect(
        Entitlements.revalidateShouldRevoke(
          transactionCount: 1,
          entitledProduct: null,
        ),
        isTrue,
      );
    });

    test('a still-valid transaction keeps the entitlement', () {
      expect(
        Entitlements.revalidateShouldRevoke(
          transactionCount: 1,
          entitledProduct: 'dp_premium_lifetime_2026',
        ),
        isFalse,
      );
    });
  });

  group('isEntitledTransaction', () {
    test('a live subscription entitles', () {
      expect(
        Entitlements.isEntitledTransaction(
          productId: 'dp_premium_monthly_2026',
          expirationMs: DateTime.now()
                  .add(const Duration(days: 1))
                  .millisecondsSinceEpoch,
          revocationMs: null,
        ),
        isTrue,
      );
    });

    test('a revoked transaction never entitles, even before its expiry', () {
      expect(
        Entitlements.isEntitledTransaction(
          productId: 'dp_premium_lifetime_2026',
          expirationMs: null,
          revocationMs: DateTime.now().millisecondsSinceEpoch,
        ),
        isFalse,
      );
    });

    test('a foreign product never entitles', () {
      expect(
        Entitlements.isEntitledTransaction(
          productId: 'com.other.app.product',
          expirationMs: null,
          revocationMs: null,
        ),
        isFalse,
      );
    });
  });

  group('Apple StoreKit policy', () {
    // Apple's AppStore.sync() documentation:
    //   "Calling AppStore.sync() displays a system prompt that asks users to
    //    authenticate with their App Store credentials. Call this function
    //    only in response to an explicit user action, like tapping or
    //    clicking a button."
    // and on reinstall:
    //   "When users reinstall your app or download it on a new device, the app
    //    automatically has all transactions available to it upon initial
    //    launch."
    //
    // So the auto-reactivation must come from the transaction LISTENER, not
    // from a sync at launch. These tests pin that split, because a sync at
    // launch would put an App Store sign-in prompt in front of every user.
    late String entitlementsSource;

    setUpAll(() {
      entitlementsSource =
          File('lib/services/entitlements.dart').readAsStringSync();
    });

    test('init() starts the transaction listener (Apple: "as soon as the app launches")', () {
      final init = entitlementsSource.substring(
        entitlementsSource.indexOf('Future<void> init() async {'),
        entitlementsSource.indexOf('Future<void> _loadTrialStart()'),
      );
      expect(init, contains('startPurchaseListener()'));
    });

    test('init() never calls AppStore.sync()', () {
      final init = entitlementsSource.substring(
        entitlementsSource.indexOf('Future<void> init() async {'),
        entitlementsSource.indexOf('Future<void> _loadTrialStart()'),
      );
      expect(init, isNot(contains('syncPurchasesWithAppStore')));
    });

    test('AppStore.sync() is reachable only through restorePurchases()', () {
      // Exactly one call site in the whole service — the explicit Restore.
      final occurrences = 'syncPurchasesWithAppStore()'
          .allMatches(entitlementsSource)
          .length;
      expect(occurrences, 1);
      final restore = entitlementsSource.substring(
        entitlementsSource.indexOf('Future<void> restorePurchases() async {'),
        entitlementsSource.indexOf('/// Test-only: reset the singleton state.'),
      );
      expect(restore, contains('syncPurchasesWithAppStore()'));
    });

    test('the paywall no longer stops the launch-time listener', () {
      // The listener now lives for the whole app session: stopping it when
      // the sheet closed would put the plan back behind a Restore tap.
      final paywall =
          File('lib/screens/paywall_sheet.dart').readAsStringSync();
      expect(paywall, isNot(contains('stopPurchaseListener')));
    });

    test('the gates wait for the first entitlement read', () {
      final player = File('lib/screens/player_screen.dart').readAsStringSync();
      final settings =
          File('lib/screens/settings_screen.dart').readAsStringSync();
      expect(player, contains('awaitReady()'));
      expect(settings, contains('awaitReady()'));
    });
  });

  group('the launch scan is re-read', () {
    // StoreKit hydrates its transaction cache asynchronously, and the
    // plugin's `Transaction.all` is a one-shot read of that cache — right
    // after an app update it can come back EMPTY or PARTIAL even though the
    // customer owns the purchase. Measured in iap_debug.log on 2026-11-01:
    // 12:14:23 → empty, 12:14:13 → empty, 12:13:15 → the expired monthly
    // only, 12:16:52 → complete. One empty read is "not known yet", not "no
    // purchase", so the launch scan retries.

    test('the retry schedule fits inside the gate budget', () {
      // The gates give up waiting after 3s (awaitReady's timeout) and open
      // the paywall — a slower schedule would not help an entitled customer,
      // it would only delay a free user's paywall.
      final last = Entitlements.entitlementScanSchedule.last;
      expect(last.inMilliseconds, lessThan(3000));
      expect(Entitlements.entitlementScanSchedule.length, greaterThan(1));
      // The offsets must be increasing, or the retries would fire out of
      // order.
      final offsets = Entitlements.entitlementScanSchedule
          .map((d) => d.inMilliseconds)
          .toList();
      for (var i = 1; i < offsets.length; i++) {
        expect(offsets[i], greaterThan(offsets[i - 1]));
      }
    });

    test('init re-reads the history when the first read finds nothing',
        () async {
      final e = Entitlements.instance;
      // The debug override is the only way to switch the entitlement
      // machinery on in a test build.
      await e.setDebugFreeUser(true);
      Entitlements.launchScanSchedule = const [
        Duration.zero,
        Duration(milliseconds: 1),
        Duration(milliseconds: 2),
      ];      addTearDown(() async {
        await e.setDebugFreeUser(false);
        e.resetForTest();
      });

      await e.init();

      // The store answers nothing (no plugin in a test) → every attempt of
      // the schedule ran.
      expect(e.launchScanAttempts,
          greaterThanOrEqualTo(Entitlements.entitlementScanSchedule.length));
    });
  });

  group('the entitlement survives an app update', () {    // The iPad log (build 66) showed the whole problem in three lines:
    //   13:37:03.128 [INIT] … isAdvanced=false
    //   13:37:06.648 [ENTITLE] restored existing purchase: dp_premium_lifetime_2026
    // i.e. StoreKit's FIRST `Transaction.all` in the fresh process took 3.5
    // seconds (its transaction cache lives on the device and Apple rebuilds
    // it after a sign-in — "Clear the purchase history cache on the
    // device"). During those seconds the app did not know the customer was
    // subscribed, so Settings showed "Unlock" and a gated feature could open
    // the paywall for someone who had been paying for months.
    //
    // The fix: remember the product the STORE confirmed in the app's own data
    // container. An app UPDATE keeps that container → the entitlement is
    // known instantly, with no "Unlock" and no paywall. A REINSTALL deletes
    // it → a fresh install asks the store from scratch, which is what the
    // customer asked for.

    test('the product the store confirmed is remembered for the next launch',
        () async {
      final e = Entitlements.instance;
      await e.handlePurchaseUpdateForTest([
        _event(productId: 'dp_premium_lifetime_2026', status: 'purchased'),
      ]);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dreamplayer.lastEntitledProduct'),
          'dp_premium_lifetime_2026');
    });

    test('the next launch of the same install knows the entitlement at once',
        () async {
      // This is the "app update" case: the data container survived, so the
      // entitlement is there before StoreKit has answered anything.
      SharedPreferences.setMockInitialValues({
        'dreamplayer.lastEntitledProduct': 'dp_premium_lifetime_2026',
      });
      final e = Entitlements.instance;
      e.resetForTest();

      await e.init();

      expect(e.storeKitEntitled, isTrue);
      expect(e.entitlementKnown, isTrue);
      expect(e.isEntitled, isTrue);
      // No store call is needed for that — the answer was already known.
      expect(e.launchScanAttempts, 0);
    });

    test('a fresh install asks the store — and shows "Checking…" meanwhile',
        () async {
      // A reinstall wipes the data container: the app has no idea what the
      // customer owns until StoreKit answers. The debug override is the only
      // way to switch the entitlement machinery on in a test build (it makes
      // the paywall active, exactly like a free iOS user).
      SharedPreferences.setMockInitialValues({});
      final e = Entitlements.instance;
      e.resetForTest();
      await e.setDebugFreeUser(true);
      Entitlements.launchScanSchedule = const [
        Duration.zero,
        Duration(milliseconds: 300),
      ];
      addTearDown(() async {
        await e.setDebugFreeUser(false);
        e.resetForTest();
      });

      // While the launch scan is in flight the app must not claim "not
      // entitled" — the row shows "Checking…" instead of a false "Unlock".
      final pending = e.init();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(e.entitlementChecking, isTrue);

      await pending;

      // The store answered nothing → the app is not entitled, and now it
      // KNOWS that, so the Unlock button is correct.
      expect(e.storeKitEntitled, isFalse);
      expect(e.entitlementKnown, isTrue);
      expect(e.entitlementChecking, isFalse);
    });

    test('with the paywall off there is nothing to check', () async {
      // Every feature is free in that build, so the state counts as known
      // and the row must not sit on "Checking…" forever.
      SharedPreferences.setMockInitialValues({});
      final e = Entitlements.instance;
      e.resetForTest();

      await e.init();

      expect(e.effectivePaywallEnabled, isFalse);
      expect(e.entitlementKnown, isTrue);
      expect(e.entitlementChecking, isFalse);
    });

    test('a revoked entitlement clears the cache', () async {
      final e = Entitlements.instance;
      await e.handlePurchaseUpdateForTest([
        _event(productId: 'dp_premium_lifetime_2026', status: 'purchased'),
      ]);
      expect(e.cachedEntitlementForTest, 'dp_premium_lifetime_2026');

      await e.forgetCachedEntitlementForTest();

      expect(e.cachedEntitlementForTest, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dreamplayer.lastEntitledProduct'), isNull);
    });

    test('a monthly and a lifetime together: the lifetime is what we remember',
        () {
      // A Sandbox account can easily own both: an expired monthly from an
      // earlier test plus the lifetime unlock. The expired one does not
      // entitle (the scan already filters it out), and when several DO
      // entitle, the one that lasts longest is the one we cache — a
      // subscription would expire while the customer still owns the
      // lifetime, and the cached value is what the next launch trusts.
      expect(
        Entitlements.pickDurableProduct([
          (productId: 'dp_premium_monthly_2026', expirationMs: 1789972346000),
          (productId: 'dp_premium_lifetime_2026', expirationMs: null),
        ]),
        'dp_premium_lifetime_2026',
      );
      // The order in the history must not matter.
      expect(
        Entitlements.pickDurableProduct([
          (productId: 'dp_premium_lifetime_2026', expirationMs: null),
          (productId: 'dp_premium_monthly_2026', expirationMs: 1789972346000),
        ]),
        'dp_premium_lifetime_2026',
      );
      // Two subscriptions: the later expiry wins.
      expect(
        Entitlements.pickDurableProduct([
          (productId: 'dp_premium_monthly_2026', expirationMs: 1789972346000),
          (productId: 'dp_premium_yearly_2026', expirationMs: 1821508346000),
        ]),
        'dp_premium_yearly_2026',
      );
      expect(Entitlements.pickDurableProduct([]), isNull);
    });

    test('the Settings row waits for the answer instead of claiming "Unlock"',
        () {
      // The Settings screen is not pumped here (it pulls in the whole app
      // shell), so the shape of the row is pinned by reading it — the same
      // approach the other screen-level gates use.
      final settings =
          File('lib/screens/settings_screen.dart').readAsStringSync();
      expect(settings, contains('entitlementChecking'));
      expect(settings, contains('Checking your purchase'));
      // The old shape claimed "Unlock" unconditionally.
      expect(settings, isNot(contains('final showButton = !entitled')));
    });
  });

  group('the paywall steps aside', () {
    // The entitlement can arrive while the sheet is open — StoreKit
    // re-delivers the purchase history after an install/update/reinstall, a
    // purchase can complete on another device, or a restore can land. A
    // paywall left in front of a paying user is the worst outcome, so the
    // sheet closes itself as soon as the entitlement is there.
    testWidgets('it closes itself when the entitlement arrives', (tester) async {
      final e = Entitlements.instance;
      // Android + the debug override is the only way to open the paywall in a
      // test; it makes `isAdvanced` false, exactly like a free iOS user.
      await e.setDebugFreeUser(true);
      addTearDown(() async => e.setDebugFreeUser(false));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPaywall(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PaywallSheet), findsOneWidget);

      // The entitlement turns up — the sheet must get out of the way.
      await e.setDebugFreeUser(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PaywallSheet), findsNothing);
    });

    testWidgets('a sheet opened ON PURPOSE stays open (the Restore button)',
        (tester) async {
      // The iPad log (build 67) showed two "Restore Purchases" taps and two
      // instantly closed sheets: "entitlement was already there when the
      // sheet opened — closing it". The customer had nothing left to tap.
      final e = Entitlements.instance;
      await e.setDebugFreeUser(true);
      addTearDown(() async => e.setDebugFreeUser(false));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showPaywall(context, closeOnEntitlement: false),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PaywallSheet), findsOneWidget);

      // The entitlement is there — the sheet must STAY, so the Restore
      // button inside it can be used.
      await e.setDebugFreeUser(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PaywallSheet), findsOneWidget);
    });
  });
}
