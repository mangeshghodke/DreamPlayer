import '../models/hdr_format.dart';

/// Detects the HDR format from a title/filename hint (`HDR10+`, `Dolby
/// Vision`, `HLG`, ...).
///
/// Markers are matched as whole tokens, so feeding it a full title is safe:
/// `DV P8` is Dolby Vision but `Adventure.mkv` stays SDR (the old substring
/// test would have flagged any name containing "dv"). `+` is kept glued to
/// its number (`HDR10+`), and underscore/dash/dot/space are word separators.
/// Returns the Dolby Vision profile number (4,5,7,8,9…) from a codec or hint
/// string like `dvhe.08.06`, `dvh1.05.06`, `dvav.09.06`, `DV P8`, `profile 7`.
/// Returns null when the string is not Dolby Vision.
int? dolbyVisionProfile(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final s = raw.toLowerCase();
  // Codec form: dvhe.08.06 / dvh1.05.09 / dvav.09.06 / dovi
  final codecMatch = RegExp(r'dv(?:he|h1|av)[._\s-]*0?(\d)\b').firstMatch(s);
  if (codecMatch != null) {
    final n = int.tryParse(codecMatch.group(1)!);
    if (n != null) return n;
  }
  // Hint form: profile 8 / profile8 / p8 / dv p8
  final profileMatch =
      RegExp(r'(?:profile\s*0?([45-9])|(?:^|[^a-z0-9])p0?([45-9])\b)').firstMatch(s);
  if (profileMatch != null) {
    final v = profileMatch.group(1) ?? profileMatch.group(2);
    final n = int.tryParse(v!);
    if (n != null) return n;
  }
  // Bare dv token (unknown profile) → treat as DV but no profile number.
  if (s.contains('dv') || s.contains('dovi') || s.contains('dolby vision')) {
    // Only return null to signal generic DV; caller can still treat as DV.
    return null;
  }
  return null;
}

bool isDolbyVisionCodec(String? codec) {
  if (codec == null || codec.isEmpty) return false;
  final c = codec.toLowerCase();
  if (c.startsWith('dv')) return true;
  return dolbyVisionProfile(codec) != null;
}

String dolbyVisionLabel(String? codec, {String? fallbackHint}) {
  final p = dolbyVisionProfile(codec) ?? dolbyVisionProfile(fallbackHint);
  if (p != null) return 'Dolby Vision P$p';
  return 'Dolby Vision';
}

HdrFormat detectHdrFormat(String? hint) {
  if (hint == null || hint.isEmpty) return HdrFormat.sdr;
  final normalized = hint.toLowerCase().replaceAll('+', ' plus ').replaceAll('_', ' ').replaceAll('-', ' ');
  final tokens = normalized
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toList();
  final joined = tokens.join(' ');
  // Any DV signal → Dolby Vision (profiles 4,5,7,8,9 and future).
  if (dolbyVisionProfile(hint) != null ||
      tokens.any((t) => t == 'dv' || t == 'dovi' || t == 'dolby') ||
      tokens.any((t) =>
          t.startsWith('dvhe') || t.startsWith('dvh1') || t.startsWith('dvav') || t.startsWith('dovi'))) {
    return HdrFormat.dolbyVision;
  }
  if (joined.contains('hdr10 plus') ||
      tokens.any((t) => t.contains('hdr10plus') || t.startsWith('hdr10p'))) {
    return HdrFormat.hdr10plus;
  }
  if (tokens.any((t) => t == 'hdr' || t == 'hdr10')) return HdrFormat.hdr10;
  if (tokens.any((t) => t == 'hlg')) return HdrFormat.hlg;
  return HdrFormat.sdr;
}

/// Live HDR detection from the active video track codec (`dvhe`/`dvh1`/`dvav`)
/// and the transfer function / color space reported by the player.
///
/// Dolby Vision is best signaled by the codec (`dvhe`/`dvh1`/`dvav`);
/// otherwise the transfer function decides HDR10 vs HLG.
HdrFormat detectLiveHdrFormat({String? videoCodec, String? gamma}) {
  if (isDolbyVisionCodec(videoCodec)) return HdrFormat.dolbyVision;
  final transfer = (gamma ?? '').toLowerCase();
  if (transfer.contains('smpte2084') || transfer.contains('pq')) {
    return HdrFormat.hdr10;
  }
  if (transfer.contains('arib-std-b67') || transfer.contains('hlg')) {
    return HdrFormat.hlg;
  }
  return HdrFormat.sdr;
}

String formatAudioCodec(String? codec) {
  if (codec == null || codec.isEmpty) return 'Unknown';
  var c = codec.toLowerCase();
  // Strip MIME prefix (e.g. "audio/eac3" → "eac3")
  if (c.contains('/')) c = c.substring(c.lastIndexOf('/') + 1);
  const map = {
    'eac3': 'E-AC3',
    'ec3': 'E-AC3',
    'ac3': 'AC-3',
    'ac-3': 'AC-3',
    'dts': 'DTS',
    'dca': 'DTS',
    'dtshd': 'DTS-HD',
    'dts_hd': 'DTS-HD',
    'dtsx': 'DTS:X',
    'dts_x': 'DTS:X',
    'truehd': 'TrueHD',
    'mlp': 'TrueHD',
    'aac': 'AAC',
    'mp4a': 'AAC',
    'flac': 'FLAC',
    'alac': 'ALAC',
    'opus': 'Opus',
    'vorbis': 'Vorbis',
    'mp3': 'MP3',
    'libmp3lame': 'MP3',
    'pcm': 'PCM',
    'pcm_s16le': 'PCM',
    'pcm_s24le': 'PCM 24-bit',
    'pcm_f32le': 'PCM 32-bit float',
    's302m': 'AES3',
  };
  if (map.containsKey(c)) return map[c]!;
  // Handle compound MIME sub-paths like "vnd.dts.hd" → "dts.hd" → match on segments
  final segments = c.split('.');
  for (final seg in segments) {
    if (map.containsKey(seg)) return map[seg]!;
  }
  // Handle "vnd.xxx.yyy" prefix stripping (DTS MIME from MediaExtractor / EBML)
  if (c.startsWith('vnd.')) {
    final stripped = c.substring(4); // "vnd.dts.hd" → "dts.hd"
    if (map.containsKey(stripped)) return map[stripped]!;
    for (final seg in stripped.split('.')) {
      if (map.containsKey(seg)) return map[seg]!;
    }
  }
  return codec.toUpperCase();
}

String formatVideoCodec(String? codec) {
  if (codec == null || codec.isEmpty) return 'Unknown';
  var c = codec.toLowerCase();
  // Strip MIME prefix (e.g. "video/hevc" → "hevc")
  if (c.contains('/')) c = c.substring(c.lastIndexOf('/') + 1);
  // Codec strings from Media3/containers carry a profile suffix
  // (e.g. `dvhe.08.06`, `hvc1.2.4.L153.B0`); match on the leading token.
  final primary = c.split(RegExp(r'[.\s]')).first;
  const map = {
    'h264': 'H.264',
    'avc1': 'H.264',
    'hevc': 'HEVC',
    'h265': 'HEVC',
    'hvc1': 'HEVC',
    'hev1': 'HEVC',
    'dvhe': 'Dolby Vision',
    'dvh1': 'Dolby Vision',
    'dvav': 'Dolby Vision',
    'av01': 'AV1',
    'av1': 'AV1',
    'vp9': 'VP9',
    'vp09': 'VP9',
    'mpeg2video': 'MPEG-2',
    'mpeg4': 'MPEG-4',
    'mp4v': 'MPEG-4',
    'vc1': 'VC-1',
    'mjpeg': 'MJPEG',
  };
  return map[primary] ?? c.toUpperCase();
}

/// Maps a Media3 audio MIME type + codecs string pair to a display label.
///
/// Media3 reports lossless/HD formats via MIME (`audio/vnd.dts.hd`,
/// `audio/vnd.dolby.truehd`, ...) while the codecs string is often generic
/// (`dts`, `mlp`); the MIME is authoritative when present.
String formatMedia3Audio(String? mime, String? codecs) {
  final m = (mime ?? '').toLowerCase();
  final c = (codecs ?? '').toLowerCase();
  const mimeMap = {
    'audio/vnd.dts': 'DTS',
    'audio/vnd.dts.hd': 'DTS-HD',
    'audio/eac3': 'E-AC3',
    'audio/eac3-joc': 'E-AC3',
    'audio/ac3': 'AC-3',
    'audio/vnd.dolby.truehd': 'TrueHD',
    'audio/mp4a-latm': 'AAC',
    'audio/aac': 'AAC',
    'audio/flac': 'FLAC',
    'audio/opus': 'Opus',
    'audio/vorbis': 'Vorbis',
    'audio/mpeg': 'MP3',
    'audio/raw': 'PCM',
    'audio/alac': 'ALAC',
  };
  final fromMime = mimeMap[m];
  if (fromMime != null) return fromMime;

  final primary = c.split(RegExp(r'[.\s/]')).first;
  const codecMap = {
    'dts': 'DTS',
    'dca': 'DTS',
    'dts-hd': 'DTS-HD',
    'dtshd': 'DTS-HD',
    'dtsx': 'DTS:X',
    'mlp': 'TrueHD',
    'truehd': 'TrueHD',
    'ac-3': 'AC-3',
    'ac3': 'AC-3',
    'ec-3': 'E-AC3',
    'eac3': 'E-AC3',
    'aac': 'AAC',
    'mp4a': 'AAC',
    'flac': 'FLAC',
    'alac': 'ALAC',
    'opus': 'Opus',
    'vorbis': 'Vorbis',
    'mp3': 'MP3',
    'pcm': 'PCM',
    'pcm_s16le': 'PCM',
    'pcm_s24le': 'PCM 24-bit',
    'pcm_f32le': 'PCM 32-bit float',
    's302m': 'AES3',
    'wavpack': 'WavPack',
    'tta': 'TTA',
    'ape': 'Monkey\'s Audio',
    'wmalossless': 'WMA Lossless',
    'atrac': 'ATRAC',
    'qdm2': 'QDesign',
  };
  final fromCodecs = codecMap[primary];
  if (fromCodecs != null) return fromCodecs;

  if (m.isNotEmpty) return m.toUpperCase();
  if (c.isNotEmpty) return c.toUpperCase();
  return 'Unknown';
}

/// Maps a subtitle track's MIME / codecs string to a display label.
///
/// Sideloaded sidecar tracks carry their original MIME in the codecs field
/// (Media3 repackages them as `application/x-media3-cues` samples); embedded
/// container tracks use the raw subtitle MIME (`application/pgs`, ...).
String formatSubtitle(String? mime, String? codecs) {
  final m = (mime ?? '').toLowerCase();
  final c = (codecs ?? '').toLowerCase();
  const map = {
    'application/x-subrip': 'SRT',
    'text/x-ssa': 'SSA/ASS',
    'text/vtt': 'WebVTT',
    'application/x-mp4vtt': 'WebVTT',
    'application/ttml+xml': 'TTML',
    'application/x-sami': 'SAMI',
    'application/x-microdvd': 'MicroDVD',
    'application/x-mpl2': 'MPL2',
    'application/pgs': 'PGS',
    'application/vobsub': 'VobSub',
    'application/dvb': 'DVB',
    'application/x-quicktime-tx3g': 'TX3G',
    'application/cea-608': 'CEA-608',
    'application/cea-708': 'CEA-708',
  };
  final viaCodecs = map[c];
  if (viaCodecs != null) return viaCodecs;
  final viaMime = map[m];
  if (viaMime != null) return viaMime;

  if (c.startsWith('application/x-media3-cues')) return 'Subtitle';
  if (c.contains('pgs')) return 'PGS';
  if (c.isNotEmpty) return c.toUpperCase();
  return 'Subtitle';
}

/// Live HDR detection from Media3 track info.
///
/// Dolby Vision is signaled by the codec prefix (`dvhe`/`dvh1`); otherwise the
/// color transfer function decides HDR10 (ST2084/PQ) vs HLG. Media3's
/// `Format.colorInfo.colorTransfer` uses the Android `MediaFormat` constants
/// (ST2084 = 6, HLG = 7).
///
/// Additionally, the native side can probe the bitstream for static HDR10
/// metadata (SEI payload types 137/144) and set `isHdr10`, covering plain
/// HDR10 MKVs that omit the MKV `Colour` element (Media3's MatroskaExtractor
/// doesn't populate `Format.colorInfo` for such files).
HdrFormat detectMedia3HdrFormat({
  int? colorTransfer,
  String? videoCodecs,
  String? videoMime,
  bool isHdr10Plus = false,
  bool isHdr10 = false,
}) {
  if (isDolbyVisionCodec(videoCodecs) || isDolbyVisionCodec(videoMime)) {
    return HdrFormat.dolbyVision;
  }
  // ST 2094-40 dynamic metadata found in the bitstream → HDR10+, even though
  // the transfer function is the same PQ used by plain HDR10.
  if (isHdr10Plus) return HdrFormat.hdr10plus;
  // Static HDR10 metadata (SEI 137/144) found in the bitstream → HDR10,
  // even when Media3's colorInfo is null (MKV Colour element omitted).
  if (isHdr10) return HdrFormat.hdr10;
  switch (colorTransfer) {
    case 6:
      return HdrFormat.hdr10;
    case 7:
      return HdrFormat.hlg;
    default:
      return HdrFormat.sdr;
  }
}

/// Formats an audio codec + decoder pair from the playback engine.
///
/// The engine may report DTS-HD tracks as codec `dts`; the HD variant shows
/// up in the decoder description (e.g. `dts (dts_hd)`). Same trick is needed
/// to distinguish lossless formats reported generically.
String formatLiveAudioCodec(String? codec, String? decoder) {
  if (codec == null || codec.isEmpty) return 'Unknown';
  final c = codec.toLowerCase();
  final dec = (decoder ?? '').toLowerCase();
  if (c == 'dts' &&
      (dec.contains('dts_hd') ||
          dec.contains('dts-hd') ||
          dec.contains('dts_mast') ||
          dec.contains('truehd'))) {
    return 'DTS-HD';
  }
  if (c == 'truehd' && dec.contains('mlp')) return 'TrueHD';
  return formatAudioCodec(codec);
}

/// Maps an ISO-639 language code to its full English name (e.g. `eng` ->
/// `English`). Falls back to the raw code when unknown.
String languageName(String? code) {
  if (code == null || code.isEmpty) return code ?? '';
  final c = code.trim().toLowerCase();
  // "und" (undefined), "zxx" (no linguistic content), "mis" (uncoded),
  // "qaa" (reserved) and similar mean "no real language" — render as empty
  // so callers (e.g. the audio chip) fall back to just the codec/label.
  const noLanguage = {
    'und',
    'undetermined',
    'zxx',
    'mis',
    'qaa',
    'mul',
    'multiple',
    'orig',
    'original',
    'unk',
    'unknown',
  };
  if (noLanguage.contains(c)) return '';
  const map = {
    'en': 'English',
    'eng': 'English',
    'de': 'German',
    'deu': 'German',
    'ger': 'German',
    'fr': 'French',
    'fre': 'French',
    'fra': 'French',
    'es': 'Spanish',
    'spa': 'Spanish',
    'it': 'Italian',
    'ita': 'Italian',
    'ja': 'Japanese',
    'jpn': 'Japanese',
    'ko': 'Korean',
    'kor': 'Korean',
    'zh': 'Chinese',
    'chi': 'Chinese',
    'zho': 'Chinese',
    'hi': 'Hindi',
    'hin': 'Hindi',
    'ta': 'Tamil',
    'tam': 'Tamil',
    'te': 'Telugu',
    'tel': 'Telugu',
    'pt': 'Portuguese',
    'por': 'Portuguese',
    'ru': 'Russian',
    'rus': 'Russian',
    'ar': 'Arabic',
    'ara': 'Arabic',
    'tr': 'Turkish',
    'tur': 'Turkish',
    'pl': 'Polish',
    'pol': 'Polish',
    'nl': 'Dutch',
    'nld': 'Dutch',
    'dut': 'Dutch',
    'sv': 'Swedish',
    'swe': 'Swedish',
    'da': 'Danish',
    'dan': 'Danish',
    'no': 'Norwegian',
    'nor': 'Norwegian',
    'fi': 'Finnish',
    'fin': 'Finnish',
    'el': 'Greek',
    'gre': 'Greek',
    'ell': 'Greek',
    'cs': 'Czech',
    'ces': 'Czech',
    'cze': 'Czech',
    'hu': 'Hungarian',
    'hun': 'Hungarian',
    'th': 'Thai',
    'tha': 'Thai',
    'vi': 'Vietnamese',
    'vie': 'Vietnamese',
    'id': 'Indonesian',
    'ind': 'Indonesian',
    'ms': 'Malay',
    'msa': 'Malay',
    'may': 'Malay',
    'uk': 'Ukrainian',
    'ukr': 'Ukrainian',
  };
  return map[c] ?? c;
}

/// Converts a channel count to a display label (e.g. `6` -> `5.1`).
String channelsLabel(int? channels) {
  if (channels == null || channels <= 0) return '?';
  switch (channels) {
    case 1:
      return 'Mono';
    case 2:
      return '2.0';
    case 6:
      return '5.1';
    case 8:
      return '7.1';
    default:
      return '$channels.0';
  }
}

/// Builds the audio chip label combining the live codec (from the playback
/// engine) with any richer profile from the library metadata.
///
/// The engine reports DTS-HD / TrueHD Atmos generically (e.g. `dts`,
/// `truehd`); the HD / Atmos distinction only lives in the metadata probe.
/// When the codec families match, prefer the metadata profile, then append
/// the live channel count.
String formatLiveAudioLabel({
  required String? liveCodec,
  String? liveDecoder,
  required int? liveChannels,
  String? metaCodec,
  String? metaProfile,
  String? liveLanguage,
}) {
  final base = formatLiveAudioCodec(liveCodec, liveDecoder);
  if (base == 'Unknown') return 'Unknown';
  var label = base;
  if (metaProfile != null && metaProfile.isNotEmpty) {
    final metaBase = formatAudioCodec(metaCodec)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final liveBase = base.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (metaBase.isNotEmpty &&
        liveBase.isNotEmpty &&
        (metaBase.contains(liveBase) || liveBase.contains(metaBase))) {
      label = '${formatAudioCodec(metaCodec)} $metaProfile';
    }
  }
  if (liveChannels != null && liveChannels > 0) {
    label = '$label ${channelsLabel(liveChannels)}';
  }
  final lang = languageName(liveLanguage);
  if (lang.isNotEmpty) {
    label = '$label · $lang';
  }
  return label;
}
