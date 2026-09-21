import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/entitlements.dart';

void main() {
  setUp(() => Entitlements.instance.resetForTest());

  group('Entitlements', () {
    test('checkGate returns notRequired when gate disabled', () {
      expect(
        checkGate(gateEnabled: false, advanced: false, paywallActive: true),
        GateResult.notRequired,
      );
    });

    test('checkGate returns notRequired when paywall inactive', () {
      expect(
        checkGate(gateEnabled: true, advanced: false, paywallActive: false),
        GateResult.notRequired,
      );
    });

    test('checkGate returns available when advanced', () {
      expect(
        checkGate(gateEnabled: true, advanced: true, paywallActive: true),
        GateResult.available,
      );
    });

    test('checkGate returns paywallNeeded when not advanced + paywall active', () {
      expect(
        checkGate(gateEnabled: true, advanced: false, paywallActive: true),
        GateResult.paywallNeeded,
      );
    });

    test('Android is always advanced (immunity guarantee)', () async {
      final e = Entitlements.instance;
      // Flutter tests run with defaultTargetPlatform == android.
      expect(e.advanced, isTrue);
      // Even after the debug override, advanced stays true on Android.
      await e.setDebugFreeUser(true);
      expect(e.advanced, isTrue);
      expect(e.isAdvanced, isFalse);
      await e.setDebugFreeUser(false);
      expect(e.advanced, isTrue);
    });

    test('7-day trial is inactive until started', () {
      final e = Entitlements.instance;
      expect(e.trialActive, isFalse);
      expect(e.isEntitled, e.isAdvanced);
    });

    test('trial is active for 7 days then expires (wall clock)', () async {
      final e = Entitlements.instance;
      await e.setDebugFreeUser(true); // paywall context (Android debug runner)
      e.setTrialStartedAtForTest(null); // discard the debug-toggle lazy start
      expect(e.trialActive, isFalse); // trial not started yet
      e.setTrialStartedAtForTest(DateTime.now());
      expect(e.trialActive, isTrue);
      expect(e.isEntitled, isTrue); // trial grants every gate
      // 6 days in -> still active.
      e.setTrialStartedAtForTest(
        DateTime.now().subtract(const Duration(days: 6, hours: 23)),
      );
      expect(e.trialActive, isTrue);
      // 7 days + 1 minute -> expired -> no longer entitled (paywall engages).
      e.setTrialStartedAtForTest(
        DateTime.now().subtract(const Duration(days: 7, minutes: 1)),
      );
      expect(e.trialActive, isFalse);
      expect(e.isEntitled, isFalse);
    });

    test('debug trial-expired override kills an active trial', () async {
      final e = Entitlements.instance;
      await e.setDebugFreeUser(true);
      e.setTrialStartedAtForTest(DateTime.now());
      expect(e.trialActive, isTrue);
      await e.setDebugTrialExpired(true);
      expect(e.trialActive, isFalse);
      expect(e.isEntitled, isFalse);
      await e.setDebugTrialExpired(false);
      expect(e.trialActive, isTrue);
    });

    test('debugFreeUser toggle does NOT auto-start the trial', () async {
      final e = Entitlements.instance;
      expect(e.trialActive, isFalse);
      await e.setDebugFreeUser(true);
      // The override flips free-user mode but does NOT start the trial;
      // the trial only begins when the user explicitly taps Start Free Trial.
      expect(e.trialActive, isFalse);
      await e.setDebugFreeUser(false);
      expect(e.debugFreeUser, isFalse);
    });

    test('startTrial sets the trial start time', () async {
      final e = Entitlements.instance;
      e.setTrialStartedAtForTest(null);
      // On Android trialActive is false unless debugFreeUser is set;
      // simulate iOS context by enabling the override so the timer matters.
      await e.setDebugFreeUser(true);
      expect(e.trialActive, isFalse);
      await e.startTrial();
      expect(e.trialActive, isTrue);
      expect(e.trialStartedEver, isTrue);
      await e.setDebugFreeUser(false);
    });

    test('debugFreeUser toggle sets free-user then restores', () async {
      final e = Entitlements.instance;
      expect(e.debugFreeUser, isFalse);
      await e.setDebugFreeUser(true);
      expect(e.debugFreeUser, isTrue);
      expect(e.isAdvanced, isFalse);
      await e.setDebugFreeUser(false);
      expect(e.debugFreeUser, isFalse);
      expect(e.isAdvanced, e.advanced);
    });
  });
}