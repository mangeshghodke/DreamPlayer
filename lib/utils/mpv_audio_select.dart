import 'package:media_kit/media_kit.dart';

/// Picks the container-default MPV audio track from [tracks].
///
/// Returns the first track whose `isDefault == true`, or null when none is
/// flagged (or the flag was never parsed into the Dart model). Sentinel
/// entries (`auto` / `no`) are ignored even if a malformed list carries them.
String? pickMpvDefaultAudioId(List<AudioTrack> tracks) {
  for (final t in tracks) {
    final id = t.id;
    if (id == 'auto' || id == 'no') continue;
    if (t.isDefault == true) return id;
  }
  return null;
}

/// Parses one `track-list/<n>/default` property value from libmpv.
/// Accepts the usual yes/no/true/false/1/0 spellings; anything else is null.
bool? parseMpvDefaultFlag(String raw) {
  final v = raw.trim().toLowerCase();
  if (v.isEmpty) return null;
  if (v == 'yes' || v == 'true' || v == '1') return true;
  if (v == 'no' || v == 'false' || v == '0') return false;
  return null;
}
