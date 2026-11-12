import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/app.dart';
import 'package:dream_player/services/layout_store.dart';

/// iPhone Duo (foldable) support — pins the three window shapes the article
/// on foldable Flutter apps calls out, plus the width-based grid rule:
///
///  * folded "cover" screen  — a short, WIDE phone (~852x393 logical)
///  * open "inner" screen    — iPad-mini-ish 4:3 (~1100x850 logical)
///  * inner screen in Split View — a narrow window (~430x850 logical)
///
/// The app must lay out from constraints (never device checks): no overflow
/// at any of the three, and the home grid column count follows the width.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpAt(WidgetTester tester, double logicalW, double logicalH,
      {double dpr = 2.0}) async {
    tester.view.physicalSize = Size(logicalW * dpr, logicalH * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const DreamPlayerApp());
    await tester.pumpAndSettle();
  }

  testWidgets('Duo folded (cover, short+wide) renders without overflow',
      (tester) async {
    await pumpAt(tester, 852, 393);
    expect(tester.takeException(), isNull);
    expect(find.text('DreamPlayer'), findsOneWidget);
  });

  testWidgets('Duo open (inner, ~4:3 wide) renders without overflow',
      (tester) async {
    await pumpAt(tester, 1100, 850);
    expect(tester.takeException(), isNull);
    expect(find.text('DreamPlayer'), findsOneWidget);
  });

  testWidgets('Duo inner in Split View (narrow window) renders without overflow',
      (tester) async {
    await pumpAt(tester, 430, 850);
    expect(tester.takeException(), isNull);
  });

  test('grid columns follow width, not device (Duo sizes included)', () {
    // phone portrait
    expect(LayoutStore.autoColumnsForWidth(390), 2);
    // Duo folded cover (wide+short): 4 columns, NOT a phone layout
    expect(LayoutStore.autoColumnsForWidth(852), 4);
    // Duo open inner: 6 columns
    expect(LayoutStore.autoColumnsForWidth(1100), 6);
    // Split View narrow window on the inner screen: back to phone-like
    expect(LayoutStore.autoColumnsForWidth(430), 2);
  });
}
