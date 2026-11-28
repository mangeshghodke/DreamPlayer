/// Embedded (often time-synced) lyrics, in LRC form, extracted from audio
/// files (FLAC `LYRICS` vorbis comment, ID3v2 `USLT`/`SYLT`, MP4 `©lyr`)
/// by the native MediaProbe on both platforms (user request 2026-11-28).
library;

/// One timestamped lyric line.
class LrcLine {
  const LrcLine(this.timeMs, this.text);
  final int timeMs;
  final String text;
}

final RegExp _lrcTag = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// True when [raw] carries at least one `[mm:ss.xx]` timestamp - i.e. it is
/// time-synced and can be highlighted against the playhead. Metadata tags
/// (`[ti:...]`, `[ar:...]`, `[offset:...]`) do not count.
bool isSyncedLrc(String? raw) {
  if (raw == null || raw.isEmpty) return false;
  for (final line in raw.split('\n')) {
    final m = _lrcTag.firstMatch(line);
    if (m != null) {
      // A metadata tag like [ti:Title] never matches the mm:ss pattern, but a
      // line like [00:00.00] does - only count real timestamps.
      final min = int.parse(m.group(1)!);
      final sec = int.parse(m.group(2)!);
      if (sec < 60) return true;
      // [offset:500] style tags use one big number; guard against those.
      if (min >= 60) continue;
      return true;
    }
  }
  return false;
}

/// Parses LRC text into timestamped lines. A line may carry several tags
/// (`[00:10.00][00:20.00]text`) - one [LrcLine] per tag. Metadata tags
/// (`[ti:]`, `[ar:]`, `[al:]`, `[by:]`, `[offset:]`, ...) yield no lines.
/// Untagged lines are dropped when any synced line exists; a fully unsynced
/// lyric block is returned as a single line at 0 ms so it can still display.
List<LrcLine> parseLrcLines(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  final out = <LrcLine>[];
  final untagged = <String>[];
  for (final rawLine in raw.split('\n')) {
    final line = rawLine.trimRight();
    if (line.isEmpty) continue;
    final tags = _lrcTag.allMatches(line).toList();
    if (tags.isEmpty) {
      untagged.add(line);
      continue;
    }
    var text = line;
    for (final t in tags) {
      text = text.replaceFirst(t.group(0) ?? '', '');
    }
    text = text.trim();
    if (text.isEmpty) continue;
    for (final t in tags) {
      final min = int.parse(t.group(1)!);
      final sec = int.parse(t.group(2)!);
      if (sec >= 60) continue; // not a real timestamp (e.g. [offset:...])
      final frac = t.group(3);
      final fracMs = frac == null
          ? 0
          : (frac.length == 3
              ? int.parse(frac)
              : frac.length == 2
                  ? int.parse(frac) * 10
                  : int.parse(frac) * 100);
      out.add(LrcLine((min * 60 + sec) * 1000 + fracMs, text));
    }
  }
  if (out.isNotEmpty) {
    out.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return out;
  }
  // Fully unsynced lyrics: keep as one block at 0 ms.
  final text = untagged.join('\n').trim();
  if (text.isEmpty) return const [];
  return [LrcLine(0, text)];
}

/// Index of the line active at [positionMs]: the last line whose timestamp is
/// at or before the position. -1 when the position is before the first line.
int lrcIndexAt(List<LrcLine> lines, int positionMs) {
  var idx = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].timeMs <= positionMs) {
      idx = i;
    } else {
      break;
    }
  }
  return idx;
}
