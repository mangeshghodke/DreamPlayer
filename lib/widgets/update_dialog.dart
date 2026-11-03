import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_updater.dart';
import 'package:url_launcher/url_launcher.dart';

/// The in-app update prompt. Covers the whole sideload flow: notes, download
/// with progress, the "install unknown apps" prompt, and the final installer
/// hand-off.
Future<void> showAppUpdateDialog(BuildContext context, AvailableUpdate update) {
  return showDialog<void>(
    context: context,
    // Dismissing mid-download would leave an orphaned transfer with no UI to
    // cancel it. The prompt itself has a Later button.
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(update: update),
  );
}

enum _Phase { prompt, downloading, error }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.update});

  final AvailableUpdate update;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _Phase _phase = _Phase.prompt;
  double? _progress;
  int _received = 0;
  int _total = 0;
  bool _cancelled = false;
  String? _error;

  Future<void> _startDownload() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _received = 0;
      _total = 0;
      _cancelled = false;
      _error = null;
    });
    try {
      final apk = await AppUpdater.download(
        widget.update,
        isCancelled: () => _cancelled,
        onProgress: (p, received, total) {
          if (!mounted || _cancelled) return;
          // A 100 MB transfer emits thousands of chunks; only repaint when the
          // shown percentage actually moves.
          if (p != null && p < 1 && _progress != null) {
            final shown = (_progress! * 100).floor();
            final next = (p * 100).floor();
            if (shown == next) return;
          }
          setState(() {
            _progress = p;
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted || _cancelled) return;
      await _install(apk);
    } catch (e) {
      if (!mounted || _cancelled) {
        if (mounted && _cancelled) {
          setState(() {
            _cancelled = false;
            _phase = _Phase.prompt;
          });
        }
        return;
      }
      setState(() {
        _phase = _Phase.error;
        _error = e is SocketException
            ? 'Check your connection and try again.'
            : 'Download failed.';
      });
    }
  }

  Future<void> _install(File apk) async {
    try {
      // The installer intent is always fired; if the "install unknown apps"
      // grant is missing, the system installer shows its own popup with a
      // Settings button — no separate phase needed here.
      await AppUpdater.install(apk);
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _error = e.message ?? 'The installer could not be opened.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);

    return PopScope(
      canPop: _phase != _Phase.downloading,
      child: Dialog(
        backgroundColor: colorScheme.surfaceContainerHigh,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          // Keeps the changelog column readable on tablets/landscape.
          constraints: BoxConstraints(
            maxWidth: 480,
            maxHeight: size.height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(theme),
                const SizedBox(height: 20),
                _versionRow(theme),
                if (widget.update.needsOneTimeUninstall) ...[
                  const SizedBox(height: 16),
                  _uninstallWarning(theme),
                ],
                const SizedBox(height: 20),
                ..._body(theme),
                const SizedBox(height: 24),
                ..._actions(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child:           Icon(
            switch (_phase) {
              _Phase.error => Icons.error_outline_rounded,
              _ => Icons.system_update_rounded,
            },
            color: colorScheme.onPrimaryContainer,
            size: 28,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Update available',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                switch (_phase) {
                  _Phase.error => 'The update did not finish.',
                  _Phase.downloading => 'Downloading the new version…',
                  _ => 'A newer version of DreamPlayer is ready.',
                },
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _phase == _Phase.error
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _versionRow(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: _VersionChip(
              label: 'Current',
              version: widget.update.installedVersion,
            ),
          ),
          const SizedBox(width: 12),
          Icon(
            Icons.arrow_forward_rounded,
            size: 20,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: _VersionChip(
              label: 'New',
              version: widget.update.version,
              isNew: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _uninstallWarning(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 16, color: colorScheme.tertiary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'This release uses a new signing key. If the install is refused, '
            'uninstall the old app once and install again. Uninstalling clears '
            "DreamPlayer's settings and resume positions; your video files are "
            'untouched.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.tertiary,
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _body(ThemeData theme) {
    if (_phase == _Phase.downloading) return [_downloading(theme)];
    if (_phase == _Phase.error) {
      return [
        Text(
          _error ?? 'Something went wrong.',
          style: theme.textTheme.bodyMedium,
        ),
      ];
    }
    return [_notes(theme)];
  }

  Widget _notes(ThemeData theme) {
    final update = widget.update;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "What's new",
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 180),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(
              update.notes.isEmpty
                  ? 'See the release page for details.'
                  : update.notes,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(update.releasePageUrl),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Full changelog'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _downloading(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final progress = _progress;
    final percent = progress == null
        ? null
        : (progress * 100).clamp(0, 100).toStringAsFixed(0);
    final receivedLabel = _total > 0
        ? '${_megabytes(_received)} / ${_megabytes(_total)} MB'
        : _received > 0
        ? '${_megabytes(_received)} MB'
        : 'Starting…';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Downloading update',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: progress, minHeight: 6),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                receivedLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (percent != null)
                Text(
                  '$percent%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _actions(ThemeData theme) {
    switch (_phase) {
      case _Phase.prompt:
        return [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _startDownload,
              icon: const Icon(Icons.download_rounded, size: 20),
              label: const Text('Download & install'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () async {
                    await AppUpdater.skipVersion(widget.update.version);
                    if (mounted) Navigator.of(context).pop();
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Skip this version',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Later'),
                ),
              ),
            ],
          ),
        ];
      case _Phase.downloading:
        return [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => setState(() {
                _cancelled = true;
                _phase = _Phase.prompt;
              }),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Cancel'),
            ),
          ),
        ];
      case _Phase.error:
        return [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('Close'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: _startDownload,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('Try again'),
                ),
              ),
            ],
          ),
        ];
    }
  }

  static String _megabytes(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(1);
}

class _VersionChip extends StatelessWidget {
  const _VersionChip({
    required this.label,
    required this.version,
    this.isNew = false,
  });

  final String label;
  final String version;
  final bool isNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isNew ? colorScheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            'v$version',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge?.copyWith(
              color: isNew
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurfaceVariant,
              fontWeight: isNew ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
