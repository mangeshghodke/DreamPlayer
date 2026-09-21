import 'package:flutter/material.dart';

import 'package:dream_player/services/entitlements.dart';
import 'paywall_sheet.dart';

/// Full-screen trial intro shown on first launch (iOS only).
/// When the user taps "Start Free Trial", the paywall sheet opens.
class TrialIntroScreen extends StatelessWidget {
  const TrialIntroScreen({super.key});

  static const _features = [
    _Feature(Icons.videocam, 'Dolby Vision & HDR10+ playback'),
    _Feature(Icons.high_quality, 'HDR10 & HLG passthrough'),
    _Feature(Icons.subtitles, 'Subtitle styling & online search'),
    _Feature(Icons.speed, 'Playback speed control'),
    _Feature(Icons.repeat, 'A-B loop & sleep timer'),
    _Feature(Icons.download, 'Download to device'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const Spacer(flex: 2),
              // Icon
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.play_circle_fill,
                  size: 44,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'DreamPlayer',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'The premium video experience',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white54,
                ),
              ),
              const Spacer(flex: 1),
              // Features
              ..._features.map((f) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      children: [
                        Icon(f.icon, color: theme.colorScheme.primary, size: 22),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            f.label,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )),
              const Spacer(flex: 2),
              // CTA
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await showPaywall(context);
                    if (!context.mounted) return;
                    // Pop intro if user is now entitled (trial started or purchased).
                    if (Entitlements.instance.isEntitled && navigator.canPop()) {
                      navigator.pop();
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'Start 7-Day Free Trial',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text(
                  'Maybe later',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'No charge until the trial ends.\nCancel anytime in Settings.',
                style: TextStyle(
                  color: Colors.white24,
                  fontSize: 11,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _Feature {
  final IconData icon;
  final String label;
  const _Feature(this.icon, this.label);
}
