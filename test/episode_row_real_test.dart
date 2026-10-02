import 'package:dream_player/services/layout_store.dart';
import 'package:dream_player/widgets/episode_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reproduces the overflow the real screens hit, which the first test missed
/// because it used a single 22px icon as `trailing` while the real rows carry a
/// `Row` of IconButtons plus a chevron, and a subtitle `Column` that is taller
/// than one line of text.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Mirrors `folder_screen`'s episode row: overview + file size + progress
  /// under the title, and a trailing Row of two IconButtons plus a chevron.
  Widget realRow(double width) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: ListView(
              children: [
                EpisodeRow(
                  thumbBuilder: (size) =>
                      EpisodeStillThumb(stillUrl: 'still', size: size),
                  title: const Text(
                    'S02E04 · A Very Long Episode Title That Goes On',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'When a big show has a long description it wraps onto '
                        'several lines inside the subtitle block.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text('1.4 GB · 1080p · HEVC'),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.all(Radius.circular(1)),
                          child: LinearProgressIndicator(
                            value: 0.4,
                            minHeight: 2,
                          ),
                        ),
                      ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.check_circle_outline),
                        onPressed: () {},
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {},
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  // The phone from the bug report: 1440x3168 at 640dpi = 360 dp wide.
  for (final size in EpisodeThumbSize.values) {
    testWidgets('real row, 360dp phone, ${size.value}', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await LayoutStore.instance.setThumbSize(size);
      await tester.pumpWidget(realRow(360));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('real row, 360dp phone, text scale 1.3', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await LayoutStore.instance.setThumbSize(EpisodeThumbSize.large);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: realRow(360),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
