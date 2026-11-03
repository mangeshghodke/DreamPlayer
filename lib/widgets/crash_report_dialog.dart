import 'dart:io';

import 'package:flutter/material.dart';

import '../services/crash_log_share.dart';
import '../services/crash_report_upload.dart';

enum _ReportState { editing, sending, sent, failed }

/// In-app crash report: lists the debug logs that exist on the device with
/// checkboxes, a message box, and a Submit button that uploads them to the
/// configured endpoint — no mail app involved. Falls back to the platform
/// share sheet when no endpoint is configured or the upload fails.
Future<void> showCrashReportDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _CrashReportDialog(),
  );
}

class _CrashReportDialog extends StatefulWidget {
  const _CrashReportDialog();

  @override
  State<_CrashReportDialog> createState() => _CrashReportDialogState();
}

class _CrashReportDialogState extends State<_CrashReportDialog> {
  late Future<List<String>> _pathsFuture;
  final _selected = <String>{};
  final _messageController = TextEditingController();
  _ReportState _state = _ReportState.editing;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pathsFuture = existingCrashLogPaths().then((paths) {
      _selected.addAll(paths);
      // The parent build decides whether Submit is enabled, so it must
      // re-run once the selection is populated — the FutureBuilder alone
      // would not.
      if (mounted) setState(() {});
      return paths;
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selected.isEmpty) return;
    setState(() {
      _state = _ReportState.sending;
      _error = null;
    });
    try {
      if (!CrashReportUpload.isConfigured) {
        throw StateError('no endpoint configured');
      }
      final status = await CrashReportUpload.upload(
        filePaths: _selected.toList(),
        message: _messageController.text.trim(),
      );
      if (status >= 200 && status < 300) {
        if (mounted) setState(() => _state = _ReportState.sent);
      } else {
        throw HttpException('HTTP $status');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _ReportState.failed;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _fallbackToShareSheet() async {
    final paths = await existingCrashLogPaths();
    if (!mounted) return;
    Navigator.of(context).pop();
    await shareCrashLogs(paths.where(_selected.contains).toList());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return PopScope(
      canPop: _state != _ReportState.sending,
      child: Dialog(
        backgroundColor: colorScheme.surfaceContainerHigh,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        _state == _ReportState.sent
                            ? Icons.check_circle_rounded
                            : Icons.bug_report,
                        color: colorScheme.onPrimaryContainer,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        switch (_state) {
                          _ReportState.sent => 'Report sent',
                          _ReportState.failed => 'Upload failed',
                          _ReportState.sending => 'Sending…',
                          _ReportState.editing => 'Send crash report',
                        },
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_state == _ReportState.sent) ...[
                  Text(
                    'Thank you — the debug logs were sent. If the crash '
                    'repeats, send another report with the new logs.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ] else ...[
                  FutureBuilder<List<String>>(
                    future: _pathsFuture,
                    builder: (context, snapshot) {
                      final paths = snapshot.data ?? const [];
                      if (paths.isEmpty) {
                        return Text(
                          'No debug logs have been written yet. Use the app '
                          'a little and try again.',
                          style: theme.textTheme.bodyMedium,
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Attach these log files:',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          for (final path in paths)
                            CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: _selected.contains(path),
                              onChanged: _state == _ReportState.sending
                                  ? null
                                  : (v) => setState(() {
                                      if (v == true) {
                                        _selected.add(path);
                                      } else {
                                        _selected.remove(path);
                                      }
                                    }),
                              title: Text(
                                path.split('/').last,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _messageController,
                    enabled: _state != _ReportState.sending,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'What happened? (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_state == _ReportState.failed) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Could not upload ($_error). You can still send the '
                      'files through the share sheet instead.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 20),
                if (_state == _ReportState.sent)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Close'),
                    ),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: _state == _ReportState.sending
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_state == _ReportState.failed)
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _fallbackToShareSheet,
                            child: const Text('Use share sheet'),
                          ),
                        ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: _state == _ReportState.sending ||
                                  _selected.isEmpty
                              ? null
                              : _submit,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: _state == _ReportState.sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Submit'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
