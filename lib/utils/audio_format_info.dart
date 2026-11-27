/// Pure helpers for describing an audio-only file's format in the player
/// (user request 2026-11-24: "which file is playing, its metadata info, and
/// if it's high-res or lossless, its bit info").
library;

import 'codec_info.dart';

/// Container MIME → codec-name aliases (formatAudioCodec maps codec names,
/// not full MIME strings like `audio/mpeg`).
const Map<String, String> _audioMimeAlias = {
  'audio/mpeg': 'mp3',
  'audio/mp3': 'mp3',
  'audio/mp4': 'aac',
  'audio/aac': 'aac',
  'audio/x-m4a': 'aac',
  'audio/flac': 'flac',
  'audio/x-flac': 'flac',
  'audio/wav': 'wav',
  'audio/x-wav': 'wav',
  'audio/wave': 'wav',
  'audio/vnd.wave': 'wav',
  'audio/aiff': 'aiff',
  'audio/x-aiff': 'aiff',
  'audio/ogg': 'ogg',
  'audio/opus': 'opus',
  'audio/x-ms-wma': 'wma',
  'audio/eac3': 'eac3',
  'audio/ac3': 'ac3',
};

/// True for codecs that carry the original PCM samples (no lossy encode):
/// FLAC, ALAC, APE, WAV/PCM, and anything `audio/x-…` PCM-ish.
bool isLosslessCodec(String? mimeOrCodec) {
  if (mimeOrCodec == null) return false;
  final m = mimeOrCodec.toLowerCase();
  const lossless = [
    'flac', 'alac', 'ape', 'wav', 'pcm', 'lpcm', 'aiff', 'aif',
    'raw', 'l16', 'l24', 'l32', // bare PCM (`audio/raw`, `audio/L16`) is lossless
    'audio/x-flac', 'audio/flac', 'audio/x-wav', 'audio/wav', 'audio/wave',
    'audio/x-aiff', 'audio/aiff', 'audio/vnd.wave', 'audio/x-ape',
    'audio/raw',
  ];
  return lossless.any(m.contains);
}

/// Quality badges for an audio track: "Lossless" when the codec is
/// uncompressed, "Hi-Res" when the sample rate / bit depth meets the
/// Hi-Res Audio bar (>= 96 kHz, or >= 24-bit at >= 48 kHz, lossless).
List<String> audioQualityBadges({
  String? mimeOrCodec,
  int? sampleRate,
  int? bits,
}) {
  final badges = <String>[];
  final lossless = isLosslessCodec(mimeOrCodec);
  if (lossless) badges.add('Lossless');
  final rate = sampleRate ?? 0;
  final depth = bits ?? 0;
  if (lossless && (rate >= 96000 || (depth >= 24 && rate >= 48000))) {
    badges.add('Hi-Res');
  }
  return badges;
}

/// Clean display name for an audio codec/MIME (`audio/mp4` -> `AAC`,
/// `audio/x-weird` -> `WEIRD`).
String audioCodecName(String? mimeOrCodec) {
  final raw = mimeOrCodec?.toLowerCase();
  if (raw != null && _audioMimeAlias.containsKey(raw)) {
    return formatAudioCodec(_audioMimeAlias[raw]);
  }
  if (raw != null && raw.contains('/')) {
    var sub = raw.substring(raw.indexOf('/') + 1);
    if (sub.startsWith('x-')) sub = sub.substring(2);
    return formatAudioCodec(sub);
  }
  return formatAudioCodec(mimeOrCodec);
}

/// The ONE badge shown at the top of the audio-only overlay (Mpv-infinity's
/// `collapsedAudioBadgeLabel`, its 1st screenshot shows a single `AAC` pill):
/// "HI-RES LOSSLESS" / "LOSSLESS" for lossless content, else the clean codec
/// name uppercased. Empty when nothing is known.
String audioCodecBadge({String? mimeOrCodec, int? sampleRate, int? bits}) {
  if (isLosslessCodec(mimeOrCodec)) {
    final rate = sampleRate ?? 0;
    final depth = bits ?? 0;
    if (rate >= 96000 || (depth >= 24 && rate >= 48000)) return 'HI-RES LOSSLESS';
    return 'LOSSLESS';
  }
  final codec = audioCodecName(mimeOrCodec);
  if (mimeOrCodec == null || codec == 'Unknown') return '';
  return codec.toUpperCase();
}

/// Channels display like Mpv-infinity's properties sheet: "Stereo (2.0)",
/// "5.1 (5.1)", "7.1.4 (16)".
String channelsDisplay(int? count) {
  if (count == null || count <= 0) return '';
  const names = {1: 'Mono', 2: 'Stereo', 6: '5.1', 7: '6.1', 8: '7.1'};
  final layout = channelsLabel(count);
  final name = names[count] ?? layout;
  return '$name ($layout)';
}

/// Badge chips for the TOP of the audio-only overlay (Mpv-infinity puts its
/// LOSSLESS/HI-RES pill at the top under the header, not under the artwork).
/// Order: codec, sample rate (kHz), bit depth, channels, bitrate, then the
/// quality badges. Empty entries are skipped.
List<String> audioBadgeLabels({
  String? mimeOrCodec,
  int? sampleRate,
  int? bits,
  int? channels,
  int? bitrate,
}) {
  final labels = <String>[];
  final raw = mimeOrCodec?.toLowerCase();
  final codec = formatAudioCodec(
      raw != null && _audioMimeAlias.containsKey(raw) ? _audioMimeAlias[raw] : mimeOrCodec);
  if (mimeOrCodec != null && codec != 'Unknown') labels.add(codec);
  if (sampleRate != null && sampleRate > 0) {
    labels.add(sampleRate >= 1000
        ? '${(sampleRate / 1000).toStringAsFixed(sampleRate % 1000 == 0 ? 0 : 1)} kHz'
        : '$sampleRate Hz');
  }
  if (bits != null && bits > 0) labels.add('$bits-bit');
  if (channels != null && channels > 0) {
    labels.add(channels == 1 ? 'mono' : '$channels ch');
  }
  if (bitrate != null && bitrate > 0) {
    labels.add(bitrate >= 1000 ? '${(bitrate / 1000).round()} kbps' : '$bitrate bps');
  }
  labels.addAll(audioQualityBadges(
    mimeOrCodec: mimeOrCodec,
    sampleRate: sampleRate,
    bits: bits,
  ));
  return labels;
}

/// One-line summary for under the vinyl disc, e.g.
/// `FLAC · 96 kHz · 24-bit · 2 ch · 1411 kbps`.
String audioFormatSummary({
  String? mimeOrCodec,
  int? sampleRate,
  int? bits,
  int? channels,
  int? bitrate,
}) {
  final parts = <String>[];
  final raw = mimeOrCodec?.toLowerCase();
  final codec = formatAudioCodec(
      raw != null && _audioMimeAlias.containsKey(raw) ? _audioMimeAlias[raw] : mimeOrCodec);
  if (mimeOrCodec != null && codec != 'Unknown') parts.add(codec);
  if (sampleRate != null && sampleRate > 0) {
    parts.add(sampleRate >= 1000
        ? '${(sampleRate / 1000).toStringAsFixed(sampleRate % 1000 == 0 ? 0 : 1)} kHz'
        : '$sampleRate Hz');
  }
  if (bits != null && bits > 0) parts.add('$bits-bit');
  if (channels != null && channels > 0) {
    parts.add(channels == 1
        ? 'mono'
        : channels == 2
            ? '2 ch'
            : '$channels ch');
  }
  if (bitrate != null && bitrate > 0) {
    parts.add(bitrate >= 1000 ? '${(bitrate / 1000).round()} kbps' : '$bitrate bps');
  }
  return parts.join(' · ');
}
