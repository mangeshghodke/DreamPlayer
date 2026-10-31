import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/libsmb2_object_code.dart';

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
  // Linked at a DreamPlayer fork of AetherEngine (the bass shelf lives
  // there), so the link points at the exact source we ship; the project
  // and its authorship are superuser404notfound's.
  _LicenseEntry('AetherEngine (iOS engine)',
      'LGPL-3.0 + Apple Store/DRM exception',
      'https://github.com/mangeshghodke/AetherEngine'),
  _LicenseEntry('FFmpeg frameworks (iOS)',
      'LGPL-2.1 or later (no GPL components)',
      'https://github.com/superuser404notfound/FFmpegBuild'),
  // Linked statically on iOS and as a separate shared library on Android, so
  // LGPL-2.1 section 6 has to be honoured for it: the sources and the object
  // code ship with the app (see "libsmb2 source and object code" below).
  _LicenseEntry('libsmb2 (SMB2/3 client)', 'GNU LGPL v2.1',
      'https://github.com/sahlberg/libsmb2'),
  // Still shipped transitively: AetherEngineSMB depends on SMBClient, so the
  // framework is in the bundle even though nothing imports it any more.
  // Attribution is kept deliberately.
  _LicenseEntry('SMBClient (SMB2/3, transitively via AetherEngineSMB)',
      'MIT', 'https://github.com/kishikawakatsumi/SMBClient'),
  // Required by the TheTVDB v4 API terms: the attribution used to sit under
  // every TheTVDB-sourced title's overview, which was noisy. It now lives here
  // and behind the small (i) button on those screens.
  _LicenseEntry('TheTVDB (metadata: artwork, overviews, seasons/episodes)',
      'Free for non-commercial use; this product uses the TheTVDB API but is '
      'not endorsed by TheTVDB',
      'https://thetvdb.github.io/v4-api/'),
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
            const Divider(),
            const _LibSmb2ObjectCodeSection(),
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

/// libsmb2 is LGPL-2.1 and is linked statically into the iOS app, so the
/// license requires the library's object code to accompany the app: the user
/// must be able to modify libsmb2 and relink. This section says where that
/// material is, and copies the path so it can be pasted into the Files app.
class _LibSmb2ObjectCodeSection extends StatefulWidget {
  const _LibSmb2ObjectCodeSection();

  @override
  State<_LibSmb2ObjectCodeSection> createState() =>
      _LibSmb2ObjectCodeSectionState();
}

class _LibSmb2ObjectCodeSectionState
    extends State<_LibSmb2ObjectCodeSection> {
  LibSmb2ObjectCode? _state;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = await LibSmb2ObjectCode.install();
    if (!mounted) return;
    setState(() => _state = state);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _state;
    final path = state?.path;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'libsmb2 source and object code',
            style: theme.textTheme.titleMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'libsmb2 is licensed under the GNU Lesser General Public License '
            'v2.1. On iOS it is linked into this app, so LGPL-2.1 section '
            '6(a) requires its object code to accompany the app, so that you '
            'can modify libsmb2 and relink it. The archive holds the compiled '
            'object files, the complete libsmb2 sources, the license and '
            'instructions for relinking.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (path == null)
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('libsmb2-objects.zip'),
            subtitle: Text(state?.reason ??
                'Preparing the archive…'),
          )
        else
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('libsmb2-objects.zip'),
            subtitle: Text(path),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy the path',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: path));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Path copied. In the Files app, open "On My iPad" → '
                        'DreamPlayer.'),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
