/// Playable-media extension lists, shared by every file listing so a folder
/// of music shows up the same way a folder of movies does (user request:
/// ".m4a/.flac/.wav files - .m4a is Atmos music").
library;
/// The VIDEO list is also duplicated in the native browsers
/// (FileBrowser.kt / SMBClient.kt / WebDAVClient.kt / FtpClient.kt /
/// UpnpClient.kt and the Swift mirrors) - keep them in sync; a source-reading
/// test in `test/media_extensions_test.dart` pins that.
///
/// NOTE: `lib/services/tmdb_client.dart`'s `_looksLikeVideoFile` deliberately
/// keeps the VIDEO-only list - a music file must never be matched against the
/// TMDB/AVDb/r18.dev movie catalogues.

/// Container/video extensions the player can open.
const List<String> videoExtensions = [
  '.mkv', '.mp4', '.avi', '.webm', '.mov', '.ts', '.m2ts', '.mts', '.wmv',
  '.flv', '.ogv', '.ogm', '.rmvb', '.mpg', '.mpeg', '.m2v', '.vob', '.3gp',
  '.3g2', '.m4v', '.divx', '.xvid', '.strm', '.m3u', '.m3u8',
];

/// Audio-only extensions the player can open (Media3: AAC/MP3/WAV natively,
/// FLAC via the FFmpeg renderer, OGG/OPUS/WMA via FFmpeg; iOS: AVPlayer for
/// m4a/mp3/wav, AetherEngine's FFmpeg path for flac/opus). `.m4a` carries
/// Dolby Atmos as E-AC3-JOC, which the Android TV passthrough path already
/// bitstreams (`PlayerCodecs.isPassthroughFormat` includes AUDIO_E_AC3_JOC).
const List<String> audioExtensions = [
  '.m4a', '.flac', '.wav', '.mp3', '.aac', '.ogg', '.oga', '.opus', '.wma',
  '.aiff', '.aif', '.mka', '.ape', '.alac', '.caf',
];

bool isVideoFile(String name) {
  final lower = name.toLowerCase();
  return videoExtensions.any(lower.endsWith);
}

bool isAudioFile(String name) {
  final lower = name.toLowerCase();
  return audioExtensions.any(lower.endsWith);
}

/// True for anything the player can open (video OR audio). This is what file
/// listings filter on.
bool isPlayableMedia(String name) => isVideoFile(name) || isAudioFile(name);
