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
  });
}
