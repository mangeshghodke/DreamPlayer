import 'package:flutter/material.dart';

/// The transient warning pill the player's brightness / volume gesture shows
/// when it crosses a risky threshold: volume above 100% (the boost band) or
/// full brightness.
///
/// It sits above the gesture's own level pill, so the two never overlap.
class GestureWarningPill extends StatelessWidget {
  const GestureWarningPill({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        // Nearly-solid black as part of the pill itself, matching the black
        // area behind it so the accent outline stays crisp.
        color: Colors.black.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.amber,
            size: 20,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
