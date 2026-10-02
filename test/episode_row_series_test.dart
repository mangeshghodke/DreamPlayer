import 'package:dream_player/services/layout_store.dart';
import 'package:dream_player/widgets/episode_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The title and subtitle widgets below are COPIED from
/// series_seasons_screen's episode row. Hand-written stand-ins passed while the
/// real screen overflows, so the only reliable repro is the real widget tree.
class _Row extends StatelessWidget {
  const _Row({required this.hasRating});

  final bool hasRating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    const parsed = _Parsed();
    const hasEpisode = true;
    const seasonNumber = 1;
    final epData = _Episode();
    final ratingValue = 8.9;
    final fileSizeLabel = '439 MB';
    final episode = _Episode();
    const progress = 0.4;

    final titleWidget = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            epData.nameLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
      ],
    );

    final subtitleWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (episode.overview.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              episode.overview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        if (hasRating || fileSizeLabel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              [
                if (hasEpisode)
                  'S${seasonNumber.toString().padLeft(2, '0')}'
                  'E${parsed.episode.toString().padLeft(2, '0')}',
                if (hasRating) ratingValue.toStringAsFixed(1),
                if (fileSizeLabel.isNotEmpty) fileSizeLabel,
              ].join(' \u00b7 '),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        if (progress > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(1),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor:
                    AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            ),
          ),
      ],
    );

    return EpisodeRow(
      thumbBuilder: (size) => EpisodeStillThumb(stillUrl: 'still', size: size),
      title: titleWidget,
      subtitle: subtitleWidget,
      trailing: IconButton(
        icon: Icon(
          Icons.check_circle_outline,
          size: 22,
        ),
        onPressed: () {},
      ),
      onTap: () {},
    );
  }
}

class _Parsed {
  const _Parsed();
  int get episode => 5;
}

class _Episode {
  String get nameLabel => 'Tarnished Cities';
  String get overview =>
      'Hannah takes an obsessive interest in a body found in the woods.';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, EpisodeThumbSize size,
      {Size surface = const Size(360, 800), double scale = 1.0}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = surface;
    addTearDown(tester.view.reset);
    await LayoutStore.instance.setThumbSize(size);
    // The MediaQuery must go BELOW MaterialApp: MaterialApp builds its own
    // from the view, and a bare MediaQueryData() has Size.zero, which made the
    // row think it had no width and demote every size to small.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            // size must be carried through: a bare MediaQueryData() has
            // Size.zero, which zeroed the row's width and made every size
            // demote to small.
            data: MediaQueryData(
              size: surface,
              textScaler: TextScaler.linear(scale),
            ),
            child: const _Row(hasRating: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // 360 dp is this phone (1440px / 4.0).
  for (final size in EpisodeThumbSize.values) {
    testWidgets('real series row 360dp ${size.value}', (tester) async {
      await pump(tester, size);
      expect(tester.takeException(), isNull);
    });
    testWidgets('real series row 360dp ${size.value} @1.3 text',
        (tester) async {
      await pump(tester, size, scale: 1.3);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('real series row landscape 360dp-high', (tester) async {
    await pump(tester, EpisodeThumbSize.medium,
        surface: const Size(800, 360));
    expect(tester.takeException(), isNull);
  });
}
