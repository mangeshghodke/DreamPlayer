import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/entitlements.dart';

/// Fake iOS Keychain for the `dreamplayer/trial` channel.
///
/// Models the one behavior that matters: the value outlives the app being
/// deleted, while SharedPreferences (mocked here) starts empty on reinstall.
class FakeKeychain {
  /// The "device" keychain — persists across app deletion.
  final Map<String, Object?> items = {};

  /// Invoked so a test can simulate "user deleted the app".
  void wipeAppContainer() {
    // SharedPreferences are per-install, so the next getInstance() call is
    // seeded fresh by the test.
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final keychain = FakeKeychain();
  late List<MethodCall> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    keychain.items.clear();
    keychain.wipeAppContainer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dreamplayer/trial'),
            (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getTrialStartedAt':
          return keychain.items['trialStartedAt'] as int?;
        case 'setTrialStartedAt':
          keychain.items['trialStartedAt'] = call.arguments as int?;
          return null;
        default:
          return null;
      }
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('dreamplayer/trial'),
              null);
    });
  });

  Future<void> initEntitlements() async {
    Entitlements.instance.resetForTest();
    await Entitlements.instance.init();
  }

  group('trial start persistence', () {
    test('startTrial writes to BOTH SharedPreferences and the Keychain',
        () async {
      await initEntitlements();
      final e = Entitlements.instance;
      await e.setDebugFreeUser(true);
      await e.startTrial();

      expect(e.trialStartedEver, isTrue);
      expect(e.trialActive, isTrue);
      expect(keychain.items['trialStartedAt'], isA<int>());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('dreamplayer.trialStartedAt'), isA<int>());
      await e.setDebugFreeUser(false);
    });

    test('reinstall resumes the SAME trial instead of restarting it',
        () async {
      // First install: user starts the trial 3 days in.
      await initEntitlements();
      final e = Entitlements.instance;
      await e.setDebugFreeUser(true);
      final threeDaysAgo = DateTime.now()
          .subtract(const Duration(days: 3))
          .millisecondsSinceEpoch;
      e.setTrialStartedAtForTest(
        DateTime.fromMillisecondsSinceEpoch(threeDaysAgo),
      );
      await e.startTrial();
      expect(keychain.items['trialStartedAt'], threeDaysAgo);
      await e.setDebugFreeUser(false);

      // --- the user deletes the app and reinstalls from the App Store ---
      // SharedPreferences are wiped; the Keychain item is not.
      SharedPreferences.setMockInitialValues({});
      keychain.wipeAppContainer();

      await initEntitlements();
      final after = Entitlements.instance;
      expect(after.trialStartedEver, isTrue,
          reason: 'trial must be known after reinstall');
      expect(after.trialStarted!.millisecondsSinceEpoch, threeDaysAgo,
          reason: 'start time must NOT be reset to now');

      // 3 days used -> 4 days remain, NOT a fresh 7.
      expect(after.trialRemaining.inDays, greaterThanOrEqualTo(3));
      expect(after.trialRemaining.inDays, lessThanOrEqualTo(4));
      expect(after.trialActive, isTrue);
    });

    test('an expired trial stays expired after reinstall', () async {
      await initEntitlements();
      final e = Entitlements.instance;
      await e.setDebugFreeUser(true);
      final longAgo = DateTime.now()
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch;
      e.setTrialStartedAtForTest(
        DateTime.fromMillisecondsSinceEpoch(longAgo),
      );
      await e.startTrial();
      await e.setDebugFreeUser(false);

      // Reinstall.
      SharedPreferences.setMockInitialValues({});
      await initEntitlements();
      expect(Entitlements.instance.trialStartedEver, isTrue);
      expect(Entitlements.instance.trialActive, isFalse,
          reason: 'a reinstall must not resurrect an expired trial');
    });

    test('startTrial does not overwrite a Keychain-only start time', () async {
      // Keychain already holds a start time (reinstall) but init() was not
      // awaited before the paywall opened.
      keychain.items['trialStartedAt'] =
          DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch;
      Entitlements.instance.resetForTest();
      final e = Entitlements.instance;
      // Deliberately skip init() — the paywall path must be safe on its own.
      await e.startTrial();
      expect(e.trialStarted!.millisecondsSinceEpoch,
          keychain.items['trialStartedAt'],
          reason: 'startTrial must restore, not restart from now');
    });

    test('pre-Keychain installs are migrated into the Keychain', () async {
      // A legacy install: the value only ever lived in SharedPreferences.
      final legacy = DateTime.now()
          .subtract(const Duration(days: 1))
          .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'dreamplayer.trialStartedAt': legacy,
      });
      keychain.items.clear();

      await initEntitlements();
      expect(Entitlements.instance.trialStarted!.millisecondsSinceEpoch, legacy);
      expect(keychain.items['trialStartedAt'], legacy,
          reason: 'legacy start time must be backfilled so a later reinstall '
              'cannot hand out a second trial');
    });

    test('a fresh install with an empty Keychain starts a real trial',
        () async {
      await initEntitlements();
      final e = Entitlements.instance;
      expect(e.trialStartedEver, isFalse);
      await e.setDebugFreeUser(true);
      await e.startTrial();
      expect(e.trialActive, isTrue);
      // Compare seconds, not inHours: `inHours` truncates, so 167h59m reads as
      // 167 and an `> 167` assertion would flake.
      expect(e.trialRemaining.inSeconds, greaterThan(167 * 3600),
          reason: 'a fresh trial is (just under) the full 7 days');
      await e.setDebugFreeUser(false);
    });
  });

  group('channel probing', () {
    test('the keychain is probed once and then cached', () async {
      await initEntitlements();
      final e = Entitlements.instance;
      await e.setDebugFreeUser(true);
      await e.startTrial();
      int probes() =>
          calls.where((c) => c.method == 'getTrialStartedAt').length;
      final afterFirst = probes();
      // Repeated taps must not re-probe the channel — availability is cached
      // for the process lifetime. (The idempotent re-write is expected.)
      await e.startTrial();
      await e.startTrial();
      expect(probes(), afterFirst,
          reason: 'repeat startTrial calls must not re-probe the keychain');
      await e.setDebugFreeUser(false);
    });

    test('a missing channel degrades to SharedPreferences only', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('dreamplayer/trial'),
              null);
      await initEntitlements();
      final e = Entitlements.instance;
      await e.setDebugFreeUser(true);
      await e.startTrial();
      // The trial still works — it just isn't reinstall-proof on this build.
      expect(e.trialActive, isTrue);
      expect(keychain.items.containsKey('trialStartedAt'), isFalse);
      await e.setDebugFreeUser(false);
    });

    test('Android never touches the keychain channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await initEntitlements();
      final e = Entitlements.instance;
      await e.setDebugFreeUser(true);
      await e.startTrial();
      expect(calls, isEmpty,
          reason: 'Android is permanently advanced — no keychain round-trip');
      await e.setDebugFreeUser(false);
    });
  });
}
