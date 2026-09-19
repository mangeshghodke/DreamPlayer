import 'package:flutter/material.dart';

import '../services/subtitle_style.dart';

/// Subtitle appearance: size, color, background, outline and cue delay, with
/// a live preview box that mirrors what both native renderers draw.
class SubtitleSettingsScreen extends StatefulWidget {
  const SubtitleSettingsScreen({super.key});

  @override
  State<SubtitleSettingsScreen> createState() => _SubtitleSettingsScreenState();
}

class _SubtitleSettingsScreenState extends State<SubtitleSettingsScreen> {
  SubtitleStyle _style = const SubtitleStyle();
  bool _loaded = false;

  static const _sizeOptions = <(double, String)>[
    (0.8, 'S'),
    (1.0, 'M'),
    (1.25, 'L'),
    (1.5, 'XL'),
  ];

  static const _colorOptions = <int, String>{
    0xFFFFFFFF: 'White',
    0xFFFFEB3B: 'Yellow',
    0xFF80DEEA: 'Cyan',
    0xFFFFCC80: 'Warm',
  };

  static const _bgOptions = <int, String>{
    0x00000000: 'None',
    0x80000000: 'Semi',
    0xF0000000: 'Solid',
  };

  @override
  void initState() {
    super.initState();
    SubtitleStyle.load().then((style) {
      if (!mounted) return;
      setState(() {
        _style = style;
        _loaded = true;
      });
    });
  }

  Future<void> _update(SubtitleStyle style) async {
    setState(() => _style = style);
    await style.save();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Subtitles')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                // Live preview box so background boxes and outlines can be
                // judged against a non-flat backdrop (dark gradient — no
                // bundled photo). Height-capped so in landscape (short
                // viewport) it stays a strip, not a wall.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: LayoutBuilder(builder: (context, _) {
                    final media = MediaQuery.of(context).size;
                    // Adaptive: portrait sizes from width; landscape gives
                    // the preview a bigger share of the short viewport so
                    // it stays readable while the page remains scrollable.
                    final isLandscape = media.width > media.height;
                    var boxH = media.width * 9 / 16;
                    final maxH =
                        media.height * (isLandscape ? 0.42 : 0.35);
                    if (boxH > maxH) boxH = maxH;
                    if (boxH < 120) boxH = 120;
                    final boxW = boxH * 16 / 9;
                    return Center(
                      child: Container(
                        width: boxW,
                        height: boxH,
                        foregroundDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: theme.dividerColor),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF455A64),
                                      Color(0xFF0D1B20),
                                    ],
                                  ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: Padding(
                                  // Match the player overlay's logic: vPos
                                  // (0=bottom, 255=top) maps to a fraction of
                                  // the preview box height.
                                  padding: EdgeInsets.only(
                                      bottom: boxH *
                                          (_style.verticalPosition / 255.0)),
                                  child: Text(
                                    'Sample subtitle line',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize:
                                          boxH * 0.11 * _style.sizeMultiplier,
                                      fontWeight: FontWeight.w600,
                                      color: _style.color,
                                      backgroundColor: _style.hasBackground
                                          ? Color(
                                              (_style.backgroundColorValue &
                                                      0x00FFFFFF) |
                                                  ((_style.backgroundOpacity *
                                                          255
                                                          .toInt() &
                                                          0xFF) <<
                                                      24))
                                          : null,
                                      shadows: _style.outline
                                          ? const [
                                              Shadow(
                                                  color: Colors.black,
                                                  offset: Offset(1, 1)),
                                            ]
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                _section(theme, 'Text size'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<double>(
                    segments: _sizeOptions
                        .map((e) => ButtonSegment(value: e.$1, label: Text(e.$2)))
                        .toList(),
                    selected: {_nearestSize()},
                    onSelectionChanged: (selection) =>
                        _update(_style.copyWith(sizeMultiplier: selection.first)),
                  ),
                ),
                _section(theme, 'Color'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 10,
                    children: _colorOptions.entries.map((entry) {
                      final selected = _style.colorValue == entry.key;
                      return InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => _update(_style.copyWith(colorValue: entry.key)),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              width: selected ? 2.5 : 1,
                              color: selected
                                  ? theme.colorScheme.primary
                                  : theme.dividerColor,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(radius: 8, backgroundColor: Color(entry.key)),
                              const SizedBox(width: 6),
                              Text(entry.value),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                _section(theme, 'Background'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<int>(
                    segments: _bgOptions.entries
                        .map((e) => ButtonSegment(value: e.key, label: Text(e.value)))
                        .toList(),
                    selected: {_bgOptions.keys.contains(_style.backgroundColorValue)
                        ? _style.backgroundColorValue
                        : 0x00000000},
                    onSelectionChanged: (selection) => _update(
                      _style.copyWith(backgroundColorValue: selection.first),
                    ),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.format_color_text_outlined),
                  title: const Text('Black outline'),
                  subtitle: const Text('Shadow behind glyphs for readability'),
                  value: _style.outline,
                  onChanged: (value) => _update(_style.copyWith(outline: value)),
                ),
                if (_style.hasBackground) ...[
                  _section(theme, 'Background opacity'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text('${((_style.backgroundOpacity / 255.0) * 100).round()}%',
                                  style: theme.textTheme.titleMedium),
                            ),
                            TextButton(
                              onPressed: _style.backgroundOpacity == 128
                                  ? null
                                  : () => _update(_style.copyWith(backgroundOpacity: 128)),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: const Size(0, 36),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('Reset'),
                            ),
                          ],
                        ),
                        Slider(
                          min: 0.0,
                          max: 1.0,
                          divisions: 255,
                          label: '${((_style.backgroundOpacity / 255.0) * 100).round()}%',
                          value: _style.backgroundOpacity / 255.0,
                          onChanged: (v) => _update(
                            _style.copyWith(backgroundOpacity: (v * 255).round()),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                _section(theme, 'Vertical position'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('Pos: ${_style.verticalPosition}',
                                style: theme.textTheme.titleMedium),
                          ),
                          TextButton(
                            onPressed: _style.verticalPosition == 20
                                ? null
                                : () => _update(_style.copyWith(verticalPosition: 20)),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              minimumSize: const Size(0, 36),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('Reset'),
                          ),
                        ],
                      ),
                      Slider(
                        min: SubtitleStyle.minVerticalPosition.toDouble(),
                        max: SubtitleStyle.maxVerticalPosition.toDouble(),
                        divisions: SubtitleStyle.maxVerticalPosition,
                        label: '${_style.verticalPosition}',
                        value: _style.verticalPosition.toDouble(),
                        onChanged: (v) => _update(
                          _style.copyWith(verticalPosition: v.round()),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'Move subtitle text up (higher) or down (lower).',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _section(theme, 'Delay'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '${_style.delaySeconds.toStringAsFixed(2)} s',
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _style.delayMs == 0
                                ? null
                                : () => _update(_style.copyWith(delayMs: 0)),
                            icon: const Icon(Icons.restart_alt, size: 18),
                            label: const Text('Reset'),
                          ),
                        ],
                      ),
                      Slider(
                        min: SubtitleStyle.minDelayMs / 1000,
                        max: SubtitleStyle.maxDelayMs / 1000,
                        divisions: 240,
                        label:
                            '${_style.delaySeconds > 0 ? '+' : ''}${_style.delaySeconds.toStringAsFixed(2)} s',
                        value: _style.delaySeconds.clamp(
                          SubtitleStyle.minDelayMs / 1000,
                          SubtitleStyle.maxDelayMs / 1000,
                        ),
                        onChanged: (seconds) => _update(
                          _style.copyWith(delayMs: (seconds * 1000).round()),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'Positive values show subtitles later than authored — '
                          'use it to fix out-of-sync files.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                       ),
                     ],
                   ),
                 ),
               ],
             ),
           ),
     );
   }

  double _nearestSize() {
    double best = 1.0;
    double bestDist = double.infinity;
    for (final (value, _) in _sizeOptions) {
      final d = (value - _style.sizeMultiplier).abs();
      if (d < bestDist) {
        bestDist = d;
        best = value;
      }
    }
    return best;
  }

  Widget _section(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 10),
        child: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}
