/// Extracted file technical info from a filename.
class FileInfo {
  const FileInfo({
    this.videoCodec,
    this.audioCodec,
    this.audioChannels,
    this.resolution,
    this.hdrHint,
    this.fps,
  });

  final String? videoCodec;
  final String? audioCodec;
  final String? audioChannels;
  final String? resolution;
  final String? hdrHint;
  final int? fps;

  bool get isEmpty =>
      videoCodec == null &&
      audioCodec == null &&
      audioChannels == null &&
      resolution == null &&
      hdrHint == null &&
      fps == null;
}

/// Extracts video codec, audio codec, channels, resolution, HDR format,
/// and FPS from a filename. Nova-style: parses common release naming
/// conventions to populate technical metadata without reading the file.
FileInfo extractFileInfo(String fileName) {
  final name = fileName.toLowerCase();

  return FileInfo(
    videoCodec: _extractVideoCodec(name),
    audioCodec: _extractAudioCodec(name),
    audioChannels: _extractAudioChannels(name),
    resolution: _extractResolution(name),
    hdrHint: _extractHdr(name),
    fps: _extractFps(name),
  );
}

String? _extractVideoCodec(String name) {
  // Dolby Vision (must check before HEVC since dvhe contains 'hevc' patterns)
  if (name.contains(RegExp(r'\bdvhe\b|\bdvh1\b|\bdvav\b|\bdolby\.?vision\b|\bdv\b'))) {
    return 'Dolby Vision';
  }
  // HEVC / H.265
  if (name.contains(RegExp(r'\bhevc\b|\bh\.?265\b|\bhvc1\b|\bhev1\b'))) {
    return 'HEVC';
  }
  // H.264 / AVC
  if (name.contains(RegExp(r'\bh\.?264\b|\bavc1?\b|\bavc\b'))) {
    return 'H.264';
  }
  // AV1
  if (name.contains(RegExp(r'\bav0?1\b'))) {
    return 'AV1';
  }
  // VP9
  if (name.contains(RegExp(r'\bvp0?9\b|\bvp9\b'))) {
    return 'VP9';
  }
  // MPEG-2
  if (name.contains(RegExp(r'\bmpeg-?2\b'))) {
    return 'MPEG-2';
  }
  // MPEG-4
  if (name.contains(RegExp(r'\bmpeg-?4\b|\bdivx\b|\bxvid\b'))) {
    return 'MPEG-4';
  }
  return null;
}

String? _extractAudioCodec(String name) {
  // TrueHD (must check before AC3/DTS since it contains those substrings)
  if (name.contains(RegExp(r'\btruehd\b|\bmlp\b'))) {
    return 'TrueHD';
  }
  // DTS-HD MA
  if (name.contains(RegExp(r'\bdts-?hd[ ._-]*ma\b|\bdts_hd_ma\b'))) {
    return 'DTS-HD MA';
  }
  // DTS-HD
  if (name.contains(RegExp(r'\bdts-?hd\b|\bdtshd\b'))) {
    return 'DTS-HD';
  }
  // DTS:X
  if (name.contains(RegExp(r'\bdts-?x\b|\bdts_x\b'))) {
    return 'DTS:X';
  }
  // DTS
  if (name.contains(RegExp(r'\bdts\b|\bdca\b'))) {
    return 'DTS';
  }
  // Dolby Atmos (E-AC3 + Atmos)
  if (name.contains(RegExp(r'\batmos\b')) && name.contains(RegExp(r'\beac3\b|\bec-?3\b'))) {
    return 'E-AC3 Atmos';
  }
  // E-AC3 / Dolby Digital+
  if (name.contains(RegExp(r'\beac3\b|\bec-?3\b|\bddp\b'))) {
    return 'E-AC3';
  }
  // AC-3 / Dolby Digital
  if (name.contains(RegExp(r'\bac-?3\b'))) {
    return 'AC-3';
  }
  // FLAC
  if (name.contains(RegExp(r'\bflac\b'))) {
    return 'FLAC';
  }
  // AAC
  if (name.contains(RegExp(r'\baac\b'))) {
    return 'AAC';
  }
  // MP3
  if (name.contains(RegExp(r'\bmp3\b'))) {
    return 'MP3';
  }
  // Opus
  if (name.contains(RegExp(r'\bopus\b'))) {
    return 'Opus';
  }
  // ALAC
  if (name.contains(RegExp(r'\balac\b'))) {
    return 'ALAC';
  }
  // Vorbis
  if (name.contains(RegExp(r'\bvorbis\b'))) {
    return 'Vorbis';
  }
  return null;
}

String? _extractAudioChannels(String name) {
  // Match patterns like "5.1", "7.1", "2.0", "2.1", "6.1"
  final match = RegExp(r'\b(\d\.\d)\b').firstMatch(name);
  if (match != null) {
    return match.group(1);
  }
  // Match "7.1.4" (Atmos object-based)
  final matchAtmos = RegExp(r'\b(\d\.\d\.\d)\b').firstMatch(name);
  if (matchAtmos != null) {
    return matchAtmos.group(1);
  }
  return null;
}

String? _extractResolution(String name) {
  // 4320p / 8K
  if (name.contains(RegExp(r'\b4320p?\b|\b8k\b'))) {
    return '8K';
  }
  // 2160p / 4K
  if (name.contains(RegExp(r'\b2160p?\b|\b4k\b'))) {
    return '4K';
  }
  // 1080p
  if (name.contains(RegExp(r'\b1080p?\b'))) {
    return '1080p';
  }
  // 1080i
  if (name.contains(RegExp(r'\b1080i\b'))) {
    return '1080i';
  }
  // 720p
  if (name.contains(RegExp(r'\b720p?\b'))) {
    return '720p';
  }
  // 576p / 576i
  if (name.contains(RegExp(r'\b576[pi]\b'))) {
    return '576p';
  }
  // 480p / 480i
  if (name.contains(RegExp(r'\b480[pi]\b'))) {
    return '480p';
  }
  // SD (no resolution marker)
  if (name.contains(RegExp(r'\bsd\b'))) {
    return 'SD';
  }
  return null;
}

String? _extractHdr(String name) {
  // Dolby Vision (check first, it's the most specific)
  if (name.contains(RegExp(r'\bdvhe\b|\bdvh1\b|\bdvav\b|\bdolby\.?vision\b'))) {
    return 'Dolby Vision';
  }
  // DV profile
  final dvProfile = RegExp(r'\bdv?\s*p(?:rofile)?\s*(\d)\b').firstMatch(name);
  if (dvProfile != null) {
    return 'Dolby Vision P${dvProfile.group(1)}';
  }
  // HDR10+ (must check before HDR10)
  if (name.contains(RegExp(r'\bhdr10\+?\b|\bhdr10\s*plus\b'))) {
    return 'HDR10+';
  }
  // HDR10
  if (name.contains(RegExp(r'\bhdr10?\b'))) {
    return 'HDR10';
  }
  // HLG
  if (name.contains(RegExp(r'\bhlg\b'))) {
    return 'HLG';
  }
  return null;
}

int? _extractFps(String name) {
  // Match patterns like "60fps", "59.94fps", "24fps", "30fps"
  final match = RegExp(r'\b(\d{1,2}(?:\.\d+)?)\s*fps\b').firstMatch(name);
  if (match != null) {
    final fps = double.tryParse(match.group(1)!);
    if (fps != null && fps > 0 && fps <= 240) return fps.round();
  }
  // Common frame rate tags
  if (name.contains(RegExp(r'\b60fps\b|\b60p\b'))) return 60;
  if (name.contains(RegExp(r'\b50fps\b|\b50p\b'))) return 50;
  if (name.contains(RegExp(r'\b30fps\b|\b30p\b'))) return 30;
  if (name.contains(RegExp(r'\b25fps\b|\b25p\b'))) return 25;
  if (name.contains(RegExp(r'\b24fps\b|\b24p\b'))) return 24;
  if (name.contains(RegExp(r'\b23\.976\b|\b23\.98\b'))) return 24;
  return null;
}
