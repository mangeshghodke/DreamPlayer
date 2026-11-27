import 'dart:io';

/// Byte windows fetched from a remote file for metadata probing. ID3/FLAC/Vorbis
/// tags sit at the START of the file; MP4/M4A `moov` (which carries `covr`
/// artwork and the tag atoms) sits at the END unless the file is fast-start.
/// A sparse temp file with both windows lets the native metadata reader see
/// everything it needs without downloading the whole (often 30-50 MB) audio file.
const int headProbeBytes = 8 * 1024 * 1024;
const int tailProbeBytes = 4 * 1024 * 1024;

/// True when the native side cannot read this source itself and Dart has to
/// download a head+tail window to a temp file first:
/// - `ftp://`/`ftps://`/`sftp://` - neither platform's metadata reader speaks FTP,
///   and Dart's HttpClient cannot open ftp:// URIs either, so the existing
///   protocol clients are used by the caller instead (see MediaProbe).
/// - `http(s)://` with `allowSelfSigned` - the native readers use the system
///   trust store; a self-signed WebDAV/Jellyfin needs Dart's HttpClient with a
///   permissive `badCertificateCallback`.
/// SMB is NOT here: Android reads it natively through the SmbHttpProxy loopback
/// and iOS through a libsmb2 head+tail fetch (SMBBridge.fetchHeadTailToTemp).
bool needsTempDownload(String? uri, bool allowSelfSigned) {
  final u = uri ?? '';
  if (u.startsWith('ftp://') ||
      u.startsWith('ftps://') ||
      u.startsWith('sftp://')) {
    return true;
  }
  if ((u.startsWith('http://') || u.startsWith('https://')) && allowSelfSigned) {
    return true;
  }
  return false;
}

/// File extension (with dot, lowercased) of a URI/path, for naming the temp
/// file so the native probe dispatches on the right container parser
/// (`.mkv` goes to the EBML walker on iOS, for example). Empty when unknown.
String extensionOf(String uri) {
  final clean = uri.split('?').first.split('#').first;
  final name = clean.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return '.${name.substring(dot + 1).toLowerCase()}';
}

/// Server id embedded in an SMB resume key (`smb:<serverId>/<share>/<path>`),
/// used on iOS to find the saved credentials for a libsmb2 session. Null when
/// the key is missing or not an SMB key.
String? smbServerIdFromResumeKey(String? resumeKey) {
  final k = resumeKey ?? '';
  if (!k.startsWith('smb:')) return null;
  final first = k.substring(4).split('/').first;
  return first.isEmpty ? null : first;
}

/// Downloads the head [headProbeBytes] and (when the server reports a size and
/// supports Range) the tail [tailProbeBytes] of [uri] into a SPARSE temp file
/// that keeps the original extension, and returns it. The caller must delete
/// the file. Returns null on any failure - metadata probing is best-effort.
Future<File?> fetchHeadTailTempFile(
  String uri, {
  Map<String, String> headers = const {},
  bool allowSelfSigned = false,
  int headBytes = headProbeBytes,
  int tailBytes = tailProbeBytes,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('dp_probe_');
  final tempFile = File('${tempDir.path}/headtail${extensionOf(uri)}');
  HttpClient? client;
  try {
    client = HttpClient();
    if (allowSelfSigned) {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    }
    // Head: plain GET, stop after headBytes.
    final req = await client.getUrl(Uri.parse(uri));
    headers.forEach(req.headers.set);
    final resp = await req.close();
    final total = resp.contentLength; // -1 when unknown
    final raf = tempFile.openSync(mode: FileMode.write);
    try {
      var got = 0;
      await for (final chunk in resp) {
        if (got + chunk.length > headBytes) {
          raf.writeFromSync(chunk.sublist(0, headBytes - got));
          got = headBytes;
          break;
        }
        raf.writeFromSync(chunk);
        got += chunk.length;
      }
      // Tail: only when the size is known and there is more than the head.
      if (total > headBytes + tailBytes) {
        final tailReq = await client.getUrl(Uri.parse(uri));
        headers.forEach(tailReq.headers.set);
        tailReq.headers.set(HttpHeaders.rangeHeader, 'bytes=${total - tailBytes}-');
        final tailResp = await tailReq.close();
        if (tailResp.statusCode == 206) {
          var tailGot = 0;
          await for (final chunk in tailResp) {
            if (tailGot + chunk.length > tailBytes) {
              raf.setPositionSync(total - tailBytes);
              raf.writeFromSync(chunk.sublist(0, tailBytes - tailGot));
              break;
            }
            if (tailGot == 0) raf.setPositionSync(total - tailBytes);
            raf.writeFromSync(chunk);
            tailGot += chunk.length;
          }
        }
      }
    } finally {
      raf.closeSync();
    }
    return tempFile;
  } catch (_) {
    try {
      if (tempFile.existsSync()) tempFile.deleteSync();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
    return null;
  } finally {
    client?.close(force: true);
  }
}
