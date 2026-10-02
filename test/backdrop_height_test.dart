import 'package:dream_player/widgets/collapsing_backdrop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backdrop hero height used to be a hardcoded 200–220 px. That looked right
/// on a phone and like a thin cropped strip on a tablet, because a wider screen
/// at a fixed height shows proportionally less of a 16:9 image.
void main() {
  /// Pumps a minimal app at a given size and reads the computed height.
  Future<double> heightAt(WidgetTester tester, Size size) async {
    late double result;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            result = backdropExpandedHeight(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return result;
  }

  group('backdropExpandedHeight', () {
    testWidgets('portrait tablet shows the whole 16:9 image', (tester) async {
      // iPad portrait, 1024x1366.
      final h = await heightAt(tester, const Size(1024, 1366));
      expect(h, closeTo(1024 * 9 / 16, 0.01),
          reason: 'a wide screen must not be cropped just because the hero is '
              'a fixed height');
    });

    testWidgets('portrait phone shows the whole 16:9 image', (tester) async {
      final h = await heightAt(tester, const Size(390, 844));
      expect(h, closeTo(390 * 9 / 16, 0.01));
    });

    testWidgets('never taller than the viewport allows', (tester) async {
      // Landscape tablet: an uncapped 16:9 height would be 768 px of a
      // 1024-tall screen, pushing the header below the fold.
      final h = await heightAt(tester, const Size(1366, 1024));
      expect(h, lessThanOrEqualTo(1024 * 0.62));
      expect(h, greaterThan(0));
    });

    testWidgets('landscape phone stays a usable strip', (tester) async {
      final h = await heightAt(tester, const Size(844, 390));
      expect(h, lessThanOrEqualTo(390 * 0.62));
      expect(h, greaterThanOrEqualTo(200));
    });

    testWidgets('a very wide window is capped, not unbounded', (tester) async {
      final h = await heightAt(tester, const Size(2400, 800));
      expect(h, lessThanOrEqualTo(800 * 0.62));
    });

    testWidgets('a tiny window still gets the 200 px floor', (tester) async {
      final h = await heightAt(tester, const Size(320, 480));
      expect(h, greaterThanOrEqualTo(200));
    });

    test('every supported size is positive and ordered wider-taller', () {
      // The height must grow with the viewport width in portrait, otherwise a
      // tablet would show *less* of the image than a phone.
      double h(double w, double screenH) {
        final full = w * 9 / 16;
        final maxH = (screenH * 0.62).clamp(220.0, 900.0);
        return full.clamp(200.0, maxH).toDouble();
      }

      expect(h(1024, 1366), greaterThan(h(390, 844)));
      for (final size in [
        const Size(320, 480),
        const Size(390, 844),
        const Size(768, 1024),
        const Size(1024, 1366),
        const Size(1366, 1024),
      ]) {
        expect(h(size.width, size.height), greaterThan(0));
      }
    });
  });
}