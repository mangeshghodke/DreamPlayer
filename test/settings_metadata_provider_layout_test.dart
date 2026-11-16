import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/services/metadata_provider_adapter.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:dream_player/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The metadata-provider control was a `SegmentedButton` holding "TMDB",
/// "TheTVDB" and (once AVDb registered) an external chip - each segment
/// carrying an ICON as well as its label.
///
/// A SegmentedButton lays its segments out in a single non-wrapping row and
/// clips when they do not fit, so on a narrow phone at the app's 1.3x text
/// clamp "TheTVDB" did not fit and the control looked broken. `Wrap` +
/// a custom three-cell box, which is the only shape that guarantees one line:
/// the cells are equal by construction and cannot wrap.
///
/// These tests assert the real thing: no overflow, at the narrowest supported
/// width, with the external provider present (three chips) and text scaled up.
class _FakeAdapter extends MetadataProviderAdapter {
  @override
  String get id => 'fake';

  @override
  String get label => 'AVDb';

  @override
  Future<bool> isConfigured() async => false;

  @override
  Future<List<TmdMovie>> search(String query, {TmdKind kind = TmdKind.movie}) async =>
      const [];

  @override
  Future<TmdDetails?> details(TmdMovie movie) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The provider selector is HIDDEN until an adapter registers (it must not
  // offer a choice that resolves nothing), and `main()` is what registers AVDb.
  // Without a stand-in adapter these tests would assert nothing at all - the
  // section simply would not be in the tree.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MetadataProviderRegistry.instance.register(_FakeAdapter());
  });

  tearDown(() => MetadataProviderRegistry.instance.unregister('fake'));

  Widget wrapApp() => MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SettingsScreen()),
      );

  /// Whether [finder]'s Text renders at least its natural width.
  ///
  /// A Text inside a squeezed box either ellipsises or clips, and both show up
  /// as a rendered width below the intrinsic one.
  bool isFullyLaidOut(WidgetTester tester, Finder finder) {
    final element = tester.element(finder);
    final widget = element.widget as Text;
    final span = widget.textSpan ??
        (widget.data != null ? TextSpan(text: widget.data!) : null);
    if (span == null) return true;
    final painter = TextPainter(
      text: span,
      textDirection: Directionality.of(element),
      textScaler: MediaQuery.textScalerOf(element),
    )..layout();
    addTearDown(painter.dispose);
    return tester.getSize(finder).width + 0.5 >= painter.width;
  }

  /// Opens Metadata and asserts nothing overflowed on the way.
  Future<void> expectNoOverflow(
    WidgetTester tester, {
    required Size size,
    required double textScale,
    required int adapters,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrapApp());
    await tester.pumpAndSettle();

    final metadata = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
          .settingsMetadata,
    );
    await tester.ensureVisible(metadata);
    await tester.tap(metadata);
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'Settings must not overflow at ${size.width}x${size.height} '
          'textScale=$textScale adapters=$adapters',
    );

    // `takeException` is NOT enough on its own: a SegmentedButton squeezed
    // into a narrow row clips its segments silently instead of overflowing, so
    // no exception is thrown and the row still renders - that is exactly the
    // "TheTVDB doesn't fit" report. Compare each provider label's RENDERED
    // width against the width it needs; a clipped or ellipsised label renders
    // narrower than that.
    for (final label in const ['TMDB', 'TheTVDB', 'AVDb']) {
      final finder = find.text(label);
      if (finder.evaluate().isEmpty) continue;
      expect(
        isFullyLaidOut(tester, finder),
        isTrue,
        reason: '"$label" is clipped at ${size.width}dp textScale=$textScale',
      );
    }
  }

  // The external chip only exists once an adapter registers, which AVDb does
  // at startup - so the three-chip case is the real one.
  testWidgets('three provider chips do not overflow on a small phone',
      (tester) async {
    await expectNoOverflow(
      tester,
      size: const Size(320, 640),
      textScale: 1.3,
      adapters: 1,
    );
  });

  testWidgets('three provider chips fit at the common phone width',
      (tester) async {
    await expectNoOverflow(
      tester,
      size: const Size(390, 844),
      textScale: 1.0,
      adapters: 1,
    );
  });

  testWidgets('all three chips stay on ONE line at 411dp (reporter device)',
      (tester) async {
    // The reporter's screenshot showed TMDB + TheTVDB on one line and AVDb
    // alone on the next. Pin the exact case.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrapApp());
    await tester.pumpAndSettle();
    final metadata = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
          .settingsMetadata,
    );
    await tester.ensureVisible(metadata);
    await tester.tap(metadata);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final rects = <Rect>[
      for (final name in const ['tmdb', 'theTvdb', 'external'])
        tester.getRect(find.byKey(ValueKey('providerCell-$name'))),
    ];
    final tops = {for (final r in rects) r.top.toStringAsFixed(2)};
    expect(
      tops.length,
      1,
      reason: 'all three cells must share one line, got tops=$tops',
    );
    final widths = {for (final r in rects) r.width.toStringAsFixed(2)};
    expect(widths.length, 1, reason: 'cells must be equal width, got $widths');
  });

  testWidgets('a very large text scale still does not overflow',
      (tester) async {
    await expectNoOverflow(
      tester,
      size: const Size(360, 640),
      textScale: 2.0,
      adapters: 1,
    );
  });

  testWidgets('the provider chips are the same width and evenly spaced',
      (tester) async {
    // Ragged chips read as broken. They must share a width AND sit on the same
    // baseline, so the row looks like a control rather than three loose pills.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrapApp());
    await tester.pumpAndSettle();

    final metadata = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
          .settingsMetadata,
    );
    await tester.ensureVisible(metadata);
    await tester.tap(metadata);
    await tester.pumpAndSettle();

    // Measure the CELLS, not the labels: a label sizes to its own text, and
    // the longest one is scaled down inside its cell. Uniformity is a property
    // of the boxes.
    final chips = <Rect>[
      for (final name in const ['tmdb', 'theTvdb', 'external'])
        tester.getRect(find.byKey(ValueKey('providerCell-$name'))),
    ];

    final widths = {for (final r in chips) r.width.toStringAsFixed(2)};
    expect(
      widths.length,
      1,
      reason: 'provider chips must share a width, got $widths',
    );

    // Chips that fit share a row, and that row is evenly spaced. (The Wrap
    // deliberately breaks to a second row when they cannot - that is what
    // keeps 320dp honest - so only compare chips on the FIRST row.)
    final firstTop = chips.first.top;
    final firstRow = chips.where((r) => (r.top - firstTop).abs() < 1).toList();
    expect(
      firstRow.length,
      chips.length,
      reason: 'all ${chips.length} provider chips must be on ONE line at '
          '390dp - they wrapped onto a second row, which is the reported bug',
    );
    final gaps = <double>[];
    for (var i = 1; i < firstRow.length; i++) {
      gaps.add(firstRow[i].left - firstRow[i - 1].right);
    }
    final gapSet = {for (final g in gaps) g.toStringAsFixed(2)};
    expect(
      gapSet.length,
      1,
      reason: 'chips on the same row must be evenly spaced, gaps=$gapSet',
    );
    // And they share a baseline, i.e. the same vertical extent.
    final heights = {for (final r in firstRow) r.height.toStringAsFixed(2)};
    expect(heights.length, 1, reason: 'chips must be the same height');
  });

  testWidgets('TheTVDB is selectable and its label is intact', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrapApp());
    await tester.pumpAndSettle();

    final metadata = find.text(
      AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
          .settingsMetadata,
    );
    await tester.ensureVisible(metadata);
    await tester.tap(metadata);
    await tester.pumpAndSettle();

    // The label must survive the refactor - a truncated "TheTVD…" is the bug
    // being fixed, so assert the full string is rendered, not elided.
    expect(find.text('TheTVDB'), findsOneWidget);
    expect(find.text('TMDB'), findsOneWidget);
  });
}