import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/remote_servers.dart';

class RemoteServerCard extends StatelessWidget {
  const RemoteServerCard({
    super.key,
    required this.server,
    required this.onTap,
  });

  final RemoteServerEntry server;
  final VoidCallback onTap;

  IconData get _icon => switch (server.type) {
    RemoteServerType.smb => Icons.folder_shared_outlined,
    RemoteServerType.webdav => Icons.cloud_outlined,
    RemoteServerType.ftp => Icons.folder_outlined,
    RemoteServerType.jellyfin => Icons.live_tv_outlined,
  };

  String _protocol(AppLocalizations strings) => switch (server.type) {
    RemoteServerType.smb => 'SMB',
    RemoteServerType.webdav => strings.webDav,
    RemoteServerType.ftp => strings.ftpSftp,
    RemoteServerType.jellyfin => strings.jellyfin,
  };

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final auth = server.type == RemoteServerType.jellyfin
        ? (server.authenticated ? strings.signedIn : strings.signInRequired)
        : (server.username.isEmpty
              ? (server.type == RemoteServerType.smb
                    ? strings.guest
                    : strings.noLogin)
              : server.username);
    return SizedBox(
      width: 260,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                  child: Icon(_icon),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_protocol(strings)} · $auth',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                      ),
                      Text(
                        server.endpoint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colors.outline,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
