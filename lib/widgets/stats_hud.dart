import 'package:flutter/material.dart';

import '../utils/playback_stats.dart';

/// Translucent overlay panel with the live playback performance: resolution,
/// decoder, source/rendered fps, bitrates, dropped frames (Infuse-style
/// playback stats HUD). Rendered inside the video Stack — above the video,
/// above the transport chrome, but wrapped in [IgnorePointer] so it never
/// steals a gesture from the playing surface.
class PlaybackStatsHud extends StatelessWidget {
  const PlaybackStatsHud({required this.stats, super.key});

  final PlaybackStats? stats;

  @override
  Widget build(BuildContext context) {
    final lines = stats?.toLines() ?? const <String, String>{};
    return Container(
      constraints: const BoxConstraints(maxWidth: 250),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xB2000000),
        borderRadius: BorderRadius.circular(10),
      ),
      child: lines.isEmpty
          ? const Text(
              'Waiting for playback info…',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                for (final e in lines.entries)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${e.key}: ',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                        TextSpan(
                          text: e.value,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
