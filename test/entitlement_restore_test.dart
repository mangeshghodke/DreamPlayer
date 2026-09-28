import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/entitlements.dart';

/// A customer who already paid must not be locked out after an app update.
///
/// [Entitlements.refreshEntitlements] re-derives the entitlement from
/// `Transaction.all` at launch, because nothing else ever asks StoreKit what
/// the user already owns. These tests cover the decision rule it applies.
void main() {
  const monthly = 'dp_premium_monthly_2026';
  const yearly = 'dp_premium_yearly_2026';
  const lifetime = 'dp_premium_lifetime_2026';

  final now = DateTime(2026, 9, 28).millisecondsSinceEpoch;
  final inFuture = now + const Duration(days: 30).inMilliseconds;
  final inPast = now - const Duration(days: 1).inMilliseconds;

  bool entitled(String id, {int? exp, int? revoked}) =>
      Entitlements.isEntitledTransaction(
        productId: id,
        expirationMs: exp,
        revocationMs: revoked,
        nowMs: now,
      );

  group('subscriptions', () {
    test('an unexpired subscription is entitled', () {
      expect(entitled(monthly, exp: inFuture), isTrue);
      expect(entitled(yearly, exp: inFuture), isTrue);
    });

    test('an expired subscription is NOT entitled', () {
      // This is the important one: a lapsed subscription must not keep
      // premium features open, or a lapsed customer stays premium forever.
      expect(entitled(monthly, exp: inPast), isFalse);
      expect(entitled(yearly, exp: inPast), isFalse);
    });

    test('a subscription expiring exactly now is not entitled', () {
      expect(entitled(monthly, exp: now), isFalse,
          reason: 'expiry is exclusive: the period has ended');
    });

    test('a revoked (refunded) subscription is not entitled even before expiry',
        () {
      expect(entitled(monthly, exp: inFuture, revoked: now), isFalse,
          reason: 'refund must beat an otherwise-valid expiry');
      expect(entitled(yearly, exp: inFuture, revoked: now), isFalse);
    });
  });

  group('lifetime non-consumable', () {
    test('is entitled forever (no expiry)', () {
      expect(entitled(lifetime, exp: null), isTrue);
    });

    test('is revoked when the transaction was revoked', () {
      expect(entitled(lifetime, exp: null, revoked: now), isFalse,
          reason: 'a refunded lifetime must lose access');
    });
  });

  group('unrelated products', () {
    test('are ignored entirely', () {
      expect(entitled('dp_premium_something_else', exp: inFuture), isFalse);
      expect(entitled('com.other.app.product', exp: inFuture), isFalse);
      // The old, never-shipped IDs from an early design must not count.
      expect(entitled('advanced_lifetime', exp: inFuture), isFalse);
      expect(entitled('advanced_monthly', exp: inFuture), isFalse);
    });

    test('an empty/blank product id is not entitled', () {
      expect(entitled('', exp: inFuture), isFalse);
    });
  });
}
