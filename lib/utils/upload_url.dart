/// Pure helpers for the WiFi upload server (competitor-gap #1): filename
/// sanitizing and URL building. No Flutter, no IO — unit-tested in
/// `test/upload_url_test.dart`.

/// The port the upload server tries first (then port+1 … port+9, then an
/// ephemeral port).
const int kWifiUploadDefaultPort = 8080;

/// How many characters of a file name we keep (extension included).
const int kUploadNameMaxLength = 120;

/// Sanitizes a file name coming from the upload HTTP request into a safe local
/// name. Strips path components (both `/` and `\` — a browser sends the bare
/// name, but a crafted request can send `../../x`), removes control
/// characters, refuses the `.` / `..` / Windows-reserved names, caps the
/// length (keeping the extension), and falls back when nothing is left.
String sanitizeUploadName(String raw) {
  var name = raw;
  final slash = name.lastIndexOf('/');
  final backslash = name.lastIndexOf('\\');
  final cut = slash > backslash ? slash : backslash;
  if (cut >= 0) name = name.substring(cut + 1);

  // Drop control characters (0x00-0x1F, 0x7F) — they break file systems and
  // can confuse log/parse code downstream.
  name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
  name = name.trim();

  if (name.isEmpty || name == '.' || name == '..') return 'upload.bin';

  // Windows-reserved base names (CON, PRN, AUX, NUL, COM1-9, LPT1-9) — reject
  // even though we usually run on Linux/Android; the file may be synced to a
  // Windows machine via SMB later.
  final base = name.split('.').first.toUpperCase();
  const reserved = {'CON', 'PRN', 'AUX', 'NUL'};
  if (reserved.contains(base) ||
      (RegExp(r'^COM[1-9]$').hasMatch(base)) ||
      (RegExp(r'^LPT[1-9]$').hasMatch(base))) {
    name = '_$name';
  }

  if (name.length > kUploadNameMaxLength) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && name.length - dot <= 9 ? name.substring(dot) : '';
    final keep = kUploadNameMaxLength - ext.length;
    name = name.substring(0, keep) + ext;
  }
  return name;
}

/// Appends ` (2)`, ` (3)`… before the extension when [name] already exists in
/// [existingNames]. Pure so both platforms' dedup logic is testable here.
String dedupeUploadName(String name, Set<String> existingNames) {
  if (!existingNames.contains(name)) return name;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 2; i < 10000; i++) {
    final candidate = '$stem ($i)$ext';
    if (!existingNames.contains(candidate)) return candidate;
  }
  return '$stem (${DateTime.now().millisecondsSinceEpoch})$ext';
}

/// Builds the browse URLs shown to the user (and opened in a PC browser):
/// `http://<lan-ip>:<port>/u/<token>/` for each LAN address.
List<String> buildUploadUrls(
    List<String> addresses, int port, String token) {
  return addresses
      .where((a) => a.isNotEmpty)
      .map((a) => 'http://$a:$port/u/$token/')
      .toList();
}

/// The upload endpoint path for a given token: raw-body POST, file name in the
/// query (avoids multipart parsing on both native servers).
String uploadEndpointPath(String token, String fileName) {
  final enc = Uri.encodeComponent(fileName);
  return '/u/$token/upload?name=$enc';
}
