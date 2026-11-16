import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dream_player/widgets/gesture_warning_pill.dart';

void main() {
  Widget host(String message) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: GestureWarningPill(message: message),
        ),
      ),
    );
  }

  testWidgets('shows the warning text and a warning icon',
      (WidgetTester tester) async {
    await tester.pumpWidget(host('Above 100% can damage your speakers'));
    expect(find.text('Above 100% can damage your speakers'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('a long warning wraps instead of overflowing',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const message =
        'Above 100% can damage your speakers - use at your own risk';
    await tester.pumpWidget(host(message));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(message), findsOneWidget);
  });

  testWidgets('a long warning fits a narrow phone width',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(
      'Above 100% can damage your speakers - use at your own risk',
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
