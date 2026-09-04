import 'package:flutter/material.dart';

class _LicenseEntry {
  const _LicenseEntry(this.name, this.license, this.url);

  final String name;
  final String license;
  final String url;
}

const List<_LicenseEntry> _entries = [
  _LicenseEntry('DreamPlayer (this app)', 'GNU General Public License v3.0',
      'https://www.gnu.org/licenses/gpl-3.0.html'),
  _LicenseEntry('AndroidX Media3 / ExoPlayer', 'Apache License 2.0',
      'https://github.com/androidx/media'),
  _LicenseEntry('nextlib-media3ext (Android FFmpeg extension)', 'GNU GPL v3.0',
      'https://github.com/anilbeesetti/nextlib'),
  _LicenseEntry('AetherEngine (iOS engine)',
      'LGPL-3.0 + Apple Store/DRM exception',
      'https://github.com/superuser404notfound/AetherEngine'),
  _LicenseEntry('FFmpeg frameworks (iOS)',
      'LGPL-2.1 or later (no GPL components)',
      'https://github.com/superuser404notfound/FFmpegBuild'),
  _LicenseEntry('SMBClient (SMB2/3, via AetherEngineSMB for WebDAV)',
      'MIT', 'https://github.com/kishikawakatsumi/SMBClient'),
  _LicenseEntry('Flutter SDK / Dart', 'BSD 3-Clause', 'https://flutter.dev'),
  _LicenseEntry('permission_handler', 'MIT',
      'https://pub.dev/packages/permission_handler'),
  _LicenseEntry('flutter_displaymode', 'MIT',
      'https://pub.dev/packages/flutter_displaymode'),
  _LicenseEntry('shared_preferences', 'BSD 3-Clause',
      'https://pub.dev/packages/shared_preferences'),
  _LicenseEntry('cupertino_icons', 'MIT',
      'https://pub.dev/packages/cupertino_icons'),
];

/// Lists the open-source components DreamPlayer is built from and their
/// licenses. Full license texts live in the repository's NOTICE file.
class LicensesScreen extends StatelessWidget {
  const LicensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Open-source licenses')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'DreamPlayer is free software released under the GNU General '
                'Public License v3.0 (or any later version). It is built from '
                'the open-source components below; their full license texts '
                'are distributed with the app in the source repository\'s '
                'NOTICE file.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const Divider(),
            for (final entry in _entries)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(entry.name),
                subtitle: Text(entry.license),
                onTap: () => _openUrl(context, entry.url),
              ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Source code',
                style: theme.textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'The complete source code for this application is available '
                'under the GNU General Public License v3.0 at:',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('github.com/mangeshghodke/DreamPlayer'),
              subtitle: const Text('GPLv3 source code'),
              onTap: () => _openUrl(context,
                  'https://github.com/mangeshghodke/DreamPlayer'),
            ),
          ],
        ),
      ),
    );
  }

  void _openUrl(BuildContext context, String url) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(url)),
    );
  }
}
