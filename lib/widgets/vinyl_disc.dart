import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A rotating vinyl disc shown while an audio-only file plays (user request
/// 2026-11-24). If the file has embedded cover art ([artBytes]) it fills the
/// disc face (like Mpv-infinity's circular cover card); otherwise a painted
/// vinyl (grooves + label + spindle hole) is drawn. The disc spins only while
/// [spinning] is true (i.e. playback is running) - 33⅓ rpm ≈ 1.8 s per rev,
/// slowed to [spinSecondsPerRev] for a calm look.
class VinylDisc extends StatefulWidget {
  const VinylDisc({
    super.key,
    required this.spinning,
    this.artBytes,
    this.size = 240,
    this.spinSecondsPerRev = 4.0,
  });

  final bool spinning;
  final Uint8List? artBytes;
  final double size;
  final double spinSecondsPerRev;

  @override
  State<VinylDisc> createState() => _VinylDiscState();
}

class _VinylDiscState extends State<VinylDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (widget.spinSecondsPerRev * 1000).round()),
    );
    if (widget.spinning) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant VinylDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinning && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.spinning && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return SizedBox(
      width: size,
      height: size,
      child: RotationTransition(
        turns: _controller,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipOval(
              child: widget.artBytes != null
                  ? Image.memory(
                      widget.artBytes!,
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
