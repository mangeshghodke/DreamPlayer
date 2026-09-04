import 'dart:io' show Platform;

import 'ftp_client.dart';
import 'jellyfin_client.dart';
import 'smb_client.dart';
import 'webdav_client.dart';

enum RemoteServerType { smb, webdav, ftp, jellyfin }

/// Safe, presentation-oriented metadata for a configured remote server.
/// Credentials remain in the native encrypted stores / Keychain.
class RemoteServerEntry {
  const RemoteServerEntry({
    required this.type,
    required this.id,
    required this.name,
    required this.endpoint,
    this.username = '',
    this.authenticated = true,
    this.allowSelfSigned = false,
  });

  final RemoteServerType type;
  final String id;
  final String name;
  final String endpoint;
  final String username;
  final bool authenticated;
  final bool allowSelfSigned;

  String get key => '${type.name}:$id';
}

/// Aggregates the protocol-specific persisted server stores for Home.
/// Every source is isolated so one missing native plugin or corrupt store
/// cannot hide healthy servers from another source.
class RemoteServersRepository {
  RemoteServersRepository({JellyfinClient? jellyfin})
      : _jellyfin = jellyfin ?? JellyfinClient();

  final JellyfinClient _jellyfin;

  Future<List<RemoteServerEntry>> load() async {
    final groups = await Future.wait<List<RemoteServerEntry>>([
      _loadWebDav(),
      _loadFtp(),
      _loadJellyfin(),
      if (Platform.isAndroid) _loadSmb(),
    ]);
    final result = groups.expand((group) => group).toList();
    result.sort((a, b) {
      final byType = a.type.index.compareTo(b.type.index);
      return byType != 0
          ? byType
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }

  Future<List<RemoteServerEntry>> _loadWebDav() async {
    try {
      final servers = await WebDavClient.instance.listServers();
      return [
        for (final server in servers)
          RemoteServerEntry(
            type: RemoteServerType.webdav,
            id: server.id,
            name: server.name,
            endpoint: server.url,
            username: server.username,
            allowSelfSigned: server.allowSelfSigned,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<List<RemoteServerEntry>> _loadSmb() async {
    try {
      final servers = await SmbClient.instance.listServers();
      return [
        for (final server in servers)
          RemoteServerEntry(
            type: RemoteServerType.smb,
            id: server.id,
            name: server.name,
            endpoint: '${server.host}:${server.port}',
            username: server.anonymous ? '' : server.username,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<List<RemoteServerEntry>> _loadFtp() async {
    try {
      final servers = await FtpClient.instance.listServers();
      return [
        for (final server in servers)
          RemoteServerEntry(
            type: RemoteServerType.ftp,
            id: server.id,
            name: server.name,
            endpoint:
                '${server.protocolLabel.toLowerCase()}://${server.host}:${server.port}${server.path}',
            username: server.username,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<List<RemoteServerEntry>> _loadJellyfin() async {
    try {
      final servers = await _jellyfin.loadServers();
      return [
        for (final server in servers)
          RemoteServerEntry(
            type: RemoteServerType.jellyfin,
            id: server.url,
            name: server.name,
            endpoint: server.url,
            username: server.username,
            authenticated: server.isAuthenticated,
            allowSelfSigned: server.allowSelfSigned,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }
}
