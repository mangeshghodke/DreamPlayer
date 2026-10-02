import 'package:flutter/material.dart';

import 'cached_image.dart';

/// Height for a backdrop hero.
///
/// This used to be a hardcoded 200–220 px, which is why the backdrop looked
/// fine on a phone and like a thin cropped strip on a tablet. The backdrop is
/// 16:9, so at a fixed height a wider screen shows proportionally *less* of the
/// image: at 200 px tall, a 390-wide phone still fits the full width, while a
/// 1024-wide iPad can only show about a third of the image's height.
///
/// Derived from the viewport width instead, so the whole image is visible in
/// portrait on any device:
///
///  * phone portrait (390×844) → 219 px, the full image
///  * tablet portrait (1024×1366) → 576 px, the full image
///  * landscape on either → capped to a fraction of the viewport height, which
///    is the "slightly cropped in landscape" case the app has always used
///
/// The cap exists because an uncapped 16:9 height on a landscape tablet would be
/// most of the screen, pushing the header content below the fold.
double backdropExpandedHeight(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final fullImage = size.width * 9 / 16;
  final maxHeight = (size.height * 0.62).clamp(220.0, 900.0);
  return fullImage.clamp(200.0, maxHeight).toDouble();
}

/// The backdrop behind a collapsing `SliverAppBar`: the clean artwork while the
/// bar is expanded, fading out to the toolbar title as it collapses.
///
/// Shared by the details, series-seasons and manual-group screens. It was
/// duplicated verbatim in all three, which is exactly how the fixed-height
/// version ended up inconsistent in the first place.
class CollapsingBackdrop extends StatelessWidget {
  const CollapsingBackdrop({
    super.key,
    required this.backdrop,
    required this.collapsed,
  });

  final String? backdrop;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (backdrop != null)
          AnimatedOpacity(
            opacity: collapsed ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: CachedImage(
              backdrop!,
              fit: BoxFit.cover,
              // Backdrops are 16:9 and the hero height is derived to fit that
              // exactly, so this normally shows the whole image. When it does
              // have to crop (landscape), bias slightly upward: the subject in
              // movie artwork sits above centre, and a plain centre alignment
              // cuts it off.
              alignment: const Alignment(0, -0.25),
              errorBuilder: (_, _, _) =>
                  Container(color: theme.colorScheme.surfaceContainerHighest),
            ),
          )
        else
          Container(color: theme.colorScheme.surfaceContainerHighest),
      ],
    );
  }
}