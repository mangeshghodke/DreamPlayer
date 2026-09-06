import 'dart:io';

import 'package:flutter/material.dart';

import '../services/download_manager.dart';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  @override
  void initState() {
    super.initState();
    DownloadManager.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    DownloadManager.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mgr = DownloadManager.instance;
    final jobs = mgr.downloads;
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1E),
        foregroundColor: Colors.white,
        title: const Text('Downloads'),
      ),
      body: jobs.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download_done, color: Colors.white24, size: 64),
                  SizedBox(height: 16),
                  Text(
                    'No downloads yet',
                    style: TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: jobs.length,
              itemBuilder: (ctx, i) => _DownloadTile(
                job: jobs[i],
                onCancel: () => mgr.cancelDownload(jobs[i].id),
                onDelete: () => mgr.deleteDownload(jobs[i].id),
                onPlay: () => _playDownloaded(jobs[i]),
              ),
            ),
    );
  }

  void _playDownloaded(DownloadJob job) {
    if (!File(job.destPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File not found — it may have been deleted.'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    Navigator.of(context).pop(job.destPath);
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({
    required this.job,
    required this.onCancel,
    required this.onDelete,
    required this.onPlay,
  });

  final DownloadJob job;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final isActive =
        job.status == DownloadStatus.downloading || job.status == DownloadStatus.queued;
    final isDone = job.status == DownloadStatus.completed;
    final color = switch (job.status) {
      DownloadStatus.downloading => Colors.blue,
      DownloadStatus.queued => Colors.white38,
      DownloadStatus.completed => Colors.green,
      DownloadStatus.failed => Colors.red,
      DownloadStatus.cancelled => Colors.orange,
    };
    final icon = switch (job.status) {
      DownloadStatus.downloading => Icons.downloading,
      DownloadStatus.queued => Icons.schedule,
      DownloadStatus.completed => Icons.check_circle,
      DownloadStatus.failed => Icons.error,
      DownloadStatus.cancelled => Icons.cancel,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isDone ? onPlay : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: color, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        job.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isActive)
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                        onPressed: onCancel,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.white54, size: 18),
                        onPressed: onDelete,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  job.totalBytes > 0
                      ? '${job.downloadedLabel} / ${job.fileSizeLabel}  \u00b7  ${job.statusLabel}'
                      : '${job.downloadedLabel} downloaded  \u00b7  ${job.statusLabel}',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                if (isActive) ...[
                  const SizedBox(height: 8),
                  if (job.totalBytes > 0)
                    LinearProgressIndicator(
                      value: job.progress,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                    )
                  else
                    LinearProgressIndicator(
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                    ),
                ],
                if (isDone) ...[
                  const SizedBox(height: 4),
                  Text(
                    job.destPath.split('/').last,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (job.error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    job.error!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
