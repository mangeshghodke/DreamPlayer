import 'package:flutter/material.dart';

/// Compact (i) affordance shown on TheTVDB-sourced titles.
///
/// This replaced a "Metadata by TheTVDB" text link that sat under every
/// TheTVDB title's overview, which was visually noisy. The attribution text
/// itself is required by the TheTVDB v4 API terms, so it is still reachable:
/// it shows in a snackbar on tap, and is also listed in
/// Settings → About → Open-source licenses.
///
/// Opening thetvdb.com in a browser is deliberately no longer offered here.
class TheTvdbInfoButton extends StatelessWidget {
  const TheTvdbInfoButton({super.key});

  static const String attribution =
      'This product uses the TheTVDB API but is not endorsed by TheTVDB.';

  static void showAttribution(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            attribution,
            style: TextStyle(height: 1.3),
          ),
          duration: Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'About this metadata',
      iconSize: 14,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      icon: const Icon(Icons.info_outline),
      onPressed: () => showAttribution(context),
    );
  }
}
