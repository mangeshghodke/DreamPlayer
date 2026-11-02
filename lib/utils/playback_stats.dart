import 'dart:math' as math;

/// A single snapshot of the live playback performance, shown in the player's
/// stats HUD (Infuse-style overlay). One source of truth for the MPV and
/// Media3 engines + the formatting shared with the HUD widget.
class PlaybackStats {
  const PlaybackStats({
    this.width,
    this.height,
    this.sourceFps,
    this.renderedFps,
    this.videoBitrateKbps,
    this.audioBitrateKbps,
    this.videoCodec,
    this.audioLabel,
    this.decoderLine,
    this.droppedFrames,
    this.speed,
    this.durationMs,
    this.positionMs,
  });

  final int? width;
  final int? height;

  /// Frame rate as signalled by the container / format.
  final double? sourceFps;

  /// Frame rate actually rendered (measured on the Media3 engine via decoder
  /// counter deltas; mpv's `estimated-vf-fps` on the MPV engine).
  final double? renderedFps;
  final num? videoBitrateKbps;
  final num? audioBitrateKbps;
  final String? videoCodec;
  final String? audioLabel;

  /// e.g. "c2.qti.hevc.decoder · hardware" or "software".
  final String? decoderLine;

  /// Frames dropped since the last snapshot (VO + decoder), engine-dependent.
  final int? droppedFrames;
  final double? speed;
  final int? durationMs;
  final int? positionMs;

  String get resolutionLabel {
    if (width == null || height == null) return '';
    return '$width x $height';
  }

  Map<String, String> toLines() {
    final lines = <String, String>{};
    if (videoCodec != null) lines['Video'] = videoCodec!;
    if (resolutionLabel.isNotEmpty) lines['Resolution'] = resolutionLabel;
    if (decoderLine != null) lines['Decoder'] = decoderLine!;
    if (sourceFps != null) lines['Source fps'] = formatFps(sourceFps);
    if (renderedFps != null) lines['Rendered fps'] = formatFps(renderedFps);
    if (videoBitrateKbps != null) {
      lines['Video bitrate'] = formatBitrate(videoBitrateKbps!);
    }
    if (audioBitrateKbps != null) {
      lines['Audio bitrate'] = formatBitrate(audioBitrateKbps!);
    }
    if (audioLabel != null) lines['Audio'] = audioLabel!;
    if (droppedFrames != null) lines['Dropped frames'] = '$droppedFrames';
    if (speed != null) lines['Speed'] = '${speed!}x';
    if (positionMs != null && durationMs != null) {
      lines['Position'] = '${_hmss(positionMs!)} / ${_hmss(durationMs!)}';
    }
    return lines;
  }

  bool get isEmpty =>
      width == null &&
      height == null &&
      sourceFps == null &&
      renderedFps == null &&
      videoBitrateKbps == null &&
      audioBitrateKbps == null &&
      videoCodec == null &&
      audioLabel == null &&
      decoderLine == null &&
      droppedFrames == null;
}

/// Computes the RENDERED fps from two consecutive decoder-counter polls.
/// Media3 gives cumulative `renderedOutputBufferCount` values; the fps is the
/// delta divided by the elapsed time between polls. Polls while paused
/// ALONE under-report, so the meter never diffs across a count that did not
/// move (the HUD simply carries over the last measurement until the picture
/// moves again).
class RenderedFpsMeter {
  RenderedFpsMeter();

  int _lastRendered = -1;
  DateTime? _lastPoll;
  double? _lastFps;

  double? fromCounters(int rendered, DateTime now) {
    if (_lastRendered < 0 || _lastPoll == null) {
      _lastRendered = rendered;
      _lastPoll = now;
      return null;
    }
    final elapsed = now.difference(_lastPoll!).inMilliseconds / 1000.0;
    if (elapsed <= 0) return _lastFps;
    if (rendered <= _lastRendered) {
      // Paused, crashed or counters re-created on a reopen — keep the old
      // reading and re-arm on the next movement.
      _lastRendered = rendered;
      _lastPoll = now;
      return _lastFps;
    }
    final fps = (rendered - _lastRendered) / elapsed;
    _lastRendered = rendered;
    _lastPoll = now;
    _lastFps = fps;
    return fps;
  }
}

/// Parses one MPV-side stats snapshot from the raw property strings.
/// Every property is read with getProperty and may arrive empty / null /
/// non-numeric (stock libmpv, paused state, demux not started), so the
/// parser is tolerant — missing values are simply omitted from the HUD.
PlaybackStats statsFromMpvProperties({
  String? containerFps,
  String? estimatedVfFps,
  String? videoBitrate,
  String? audioBitrate,
  String? frameDropCount,
  String? decoderFrameDropCount,
  int? width,
  int? height,
  double? speed,
  int? durationMs,
  int? positionMs,
  Map<String, String?> labels = const {},
}) {
  return PlaybackStats(
    width: width,
    height: height,
    sourceFps: parseFps(containerFps),
    renderedFps: parseFps(estimatedVfFps),
    videoBitrateKbps: numOrNull(videoBitrate),
    audioBitrateKbps: numOrNull(audioBitrate),
    videoCodec: _clean(labels['video']),
    audioLabel: _clean(labels['audio']),
    decoderLine: _clean(labels['decoder']),
    droppedFrames: _sumDrops(frameDropCount, decoderFrameDropCount),
    speed: speed,
    durationMs: durationMs,
    positionMs: positionMs,
  );
}

/// Parses one Media3-side snapshot from the native `getStats` map.
PlaybackStats statsFromGetStatsMap(
  Map<Object?, Object?> raw, {
  double? renderedFps,
  Map<String, String?> labels = const {},
}) {
  return PlaybackStats(
    width: intOrNullField(raw, 'videoWidth'),
    height: intOrNullField(raw, 'videoHeight'),
    sourceFps: doubleOrNullFieldNum(raw, 'videoFps'),
    renderedFps: renderedFps,
    videoBitrateKbps: _bitsToKbps(doubleOrNullFieldNum(raw, 'videoBitrate')),
    audioBitrateKbps: _bitsToKbps(doubleOrNullFieldNum(raw, 'audioBitrate')),
    videoCodec: _clean(labels['video']),
    audioLabel: _clean(labels['audio']),
    decoderLine: _clean(labels['decoder']),
    droppedFrames: intOrNullField(raw, 'droppedBufferCount'),
    speed: doubleOrNullFieldNum(raw, 'playbackSpeed'),
    durationMs: intOrNullField(raw, 'durationMs'),
    positionMs: intOrNullField(raw, 'positionMs'),
  );
}

String? _clean(String? v) {
  if (v == null || v.isEmpty) return null;
  return v;
}

/// Bitrate text: `12500` (kbps) reads as `12.5 Mbps`, smaller stays kbps.
String formatBitrate(num kbps) {
  if (kbps >= 1000) {
    final mbps = kbps / 1000.0;
    return '${_trimZeros(mbps.toStringAsFixed(1))} Mbps';
  }
  return '${math.max(0, kbps.round())} kbps';
}

String formatFps(num? fps) {
  if (fps == null) return '';
  final v = fps.toDouble();
  if (v <= 0) return '';
  return _trimZeros(v.toStringAsFixed(2));
}

String friendlyResolutionLabel(int w, int h) {
  final long = math.max(w, h);
  final short = math.min(w, h);
  return '$short × $long';
}

double? parseFps(String? raw) {
  final v = doubleOrNull(raw);
  if (v == null || v <= 0) return null;
  return v;
}

double? doubleOrNull(String? raw) {
  final v = raw?.trim();
  if (v == null || v.isEmpty) return null;
  return double.tryParse(v);
}

int? intOrNull(String? raw) {
  final v = raw?.trim();
  if (v == null || v.isEmpty) return null;
  return int.tryParse(v) ?? double.tryParse(v)?.round();
}

num? numOrNull(String? raw) {
  final v = raw?.trim();
  if (v == null || v.isEmpty) return null;
  return num.tryParse(v);
}

int? _sumDrops(String? vo, String? decoder) {
  final a = intOrNull(vo) ?? 0;
  final b = intOrNull(decoder) ?? 0;
  final total = a + b;
  return total > 0 ? total : null;
}

num? _bitsToKbps(num? bitsPerSecond) {
  if (bitsPerSecond == null || bitsPerSecond <= 0) return null;
  return bitsPerSecond / 1000.0;
}

int? intOrNullField(Map<Object?, Object?> map, String key) {
  final v = map[key];
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return intOrNull(v);
  return null;
}

double? doubleOrNullFieldNum(Map<Object?, Object?> map, String key) {
  final v = map[key];
  if (v is num) return v.toDouble();
  if (v is String) return doubleOrNull(v);
  return null;
}

String _trimZeros(String s) {
  var t = s;
  while (t.endsWith('0')) {
    t = t.substring(0, t.length - 1);
  }
  if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  return t;
}

String _hmss(int ms) {
  final totalSeconds = ms ~/ 1000;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  final mm = h > 0 ? '$m'.padLeft(2, '0') : '$m';
  return '${h > 0 ? '$h:' : ''}$mm:${'$s'.padLeft(2, '0')}';
}
