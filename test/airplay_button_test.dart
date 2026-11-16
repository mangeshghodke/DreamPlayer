import 'package:dream_player/widgets/airplay_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the view type matches the AppDelegate registration', () {
    expect(airPlayViewType, 'dreamplayer/airplay');
  });

  testWidgets('renders nothing off iOS (no platform view to resolve)', (
    tester,
  ) async {
    // The test host is not iOS, so this also pins that the widget never asks
    // for a UiKitView the host cannot provide - a widget test would otherwise
    // hang on a platform-view creation that never answers.
    expect(AirPlayButton.isSupported, isFalse);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AirPlayButton())),
    );

    final box = tester.getSize(find.byType(AirPlayButton));
    expect(box, Size.zero);
    expect(tester.takeException(), isNull);
  });
}
