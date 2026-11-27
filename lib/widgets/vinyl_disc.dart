import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A vinyl disc shown while an audio-only file plays (user request 2026-11-24).
/// If the file has embedded cover art ([artBytes]) it fills the disc face (like
/// Mpv-infinity's circular cover card); otherwise a painted vinyl (grooves +
/// label + spindle hole) is drawn.
///
/// The rotation is PARENT-DRIVEN: the parent owns [angle] (radians) and advances
/// it - normally at ~1 rev per 4 s while playing, and directly from the user's
/// finger during a DJ-style scratch drag (user request 2026-11-27: spin the disc
/// clockwise to scrub forward, anticlockwise to scrub back, spin it fast and it
/// keeps spinning and plays fast on release). Keeping the angle in the parent
/// lets the gesture layer and the spin ticker share one source of truth.
class VinylDisc extends StatelessWidget {
  const VinylDisc({
    super.key,
    required this.angle,
    this.artBytes,
    this.size = 240,
  });

  /// Current rotation in radians. Advanced by the parent (player screen).
  final double angle;
  final Uint8List? artBytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final size = this.size;
    return SizedBox(
      width: size,
      height: size,
      child: Transform.rotate(
        angle: angle,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipOval(
              child: artBytes != null
                  ? Image.memory(
                      artBytes!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const _VinylPainter(),
                    )
                  : const _VinylPainter(),
            ),
            // Spindle hole + center label ring, drawn over the art so a
            // cover image still reads as a record.
            Center(
              child: Container(
                width: size * 0.06,
                height: size * 0.06,
                decoration: const BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Center(
              child: Container(
                width: size * 0.3,
                height: size * 0.3,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.black.withValues(alpha: 0.55),
                    width: size * 0.012,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Painted vinyl fallback: dark disc, concentric groove rings, a colored
/// center label and a spindle hole.
class _VinylPainter extends StatelessWidget {
  const _VinylPainter();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _VinylPainterImpl());
  }
}

class _VinylPainterImpl extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    // Disc body.
    final disc = Paint()..color = const Color(0xFF111114);
    canvas.drawCircle(center, radius, disc);
    // Grooves.
    final groove = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (double r = radius * 0.98; r > radius * 0.36; r -= radius * 0.045) {
      canvas.drawCircle(center, r, groove);
    }
    // Sheen (a soft highlight arc so the disc reads as 3D).
    final sheen = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..style = PaintingStyle.fill;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi * 0.8,
      math.pi * 0.9,
      true,
      sheen,
    );
    // Label.
    final label = Paint()..color = const Color(0xFF7C4DFF);
    canvas.drawCircle(center, radius * 0.3, label);
    // Spindle hole.
    final hole = Paint()..color = const Color(0xFF0E0E11);
    canvas.drawCircle(center, radius * 0.045, hole);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
