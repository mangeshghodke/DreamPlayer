import 'dart:typed_data';

/// Decoded pixel dimensions of an image, read from its header bytes only.
///
/// Used to detect WIDE posters (issue #58): adult JAV covers are a full DVD
/// sleeve (back + spine + front in one landscape image), and a centre-crop
/// card shows the back cover. When the adult-content metadata toggle is on,
/// poster cards align such images to the RIGHT (the front cover) instead.
///
/// Supports PNG, JPEG, GIF and WebP (VP8/VP8L/VP8X) — everything TMDB and
/// the external adapters serve. Pure and synchronous so it can run on
/// already-cached bytes with no decode.
class ImageSize {
  const ImageSize(this.width, this.height);

  final int width;
  final int height;

  /// True when the image is wider than it is tall (a full DVD sleeve).
  bool get isWide => width > height;
}

/// Returns the dimensions encoded in [bytes], or null when the format is
/// unrecognised or the buffer is too short. Never throws.
ImageSize? imageSizeOf(Uint8List bytes) {
  if (bytes.length < 24) return null;
  try {
    // PNG: 89 50 4E 47 0D 0A 1A 0A, then IHDR length+type, width/height BE.
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      final w = (bytes[16] << 24) |
          (bytes[17] << 16) |
          (bytes[18] << 8) |
          bytes[19];
      final h = (bytes[20] << 24) |
          (bytes[21] << 16) |
          (bytes[22] << 8) |
          bytes[23];
      return ImageSize(w, h);
    }
    // GIF: 'GIF8', width/height LE at 6/8.
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return ImageSize(
        bytes[6] | (bytes[7] << 8),
        bytes[8] | (bytes[9] << 8),
      );
    }
    // JPEG: FF D8, then walk segments for a start-of-frame marker.
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      var i = 2;
      while (i + 8 < bytes.length) {
        if (bytes[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = bytes[i + 1];
        // SOF0..SOF15 except DHT (C4), JPG (C8), DAC (CC).
        if (marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          final h = (bytes[i + 5] << 8) | bytes[i + 6];
          final w = (bytes[i + 7] << 8) | bytes[i + 8];
          return ImageSize(w, h);
        }
        // Standalone markers without a length field.
        if (marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2;
          continue;
        }
        final len = (bytes[i + 2] << 8) | bytes[i + 3];
        if (len < 2) return null;
        i += 2 + len;
      }
      return null;
    }
    // WebP: 'RIFF' size 'WEBP' then a chunk.
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      final fourcc = String.fromCharCodes(bytes, 12, 16);
      if (fourcc == 'VP8X' && bytes.length >= 30) {
        final w = 1 +
            (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
        final h = 1 +
            (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
        return ImageSize(w, h);
      }
      if (fourcc == 'VP8L' && bytes.length >= 25) {
        final b = bytes[21] |
            (bytes[22] << 8) |
            (bytes[23] << 16) |
            (bytes[24] << 24);
        return ImageSize((b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1);
      }
      if (fourcc == 'VP8 ' && bytes.length >= 30) {
        // Keyframe: 3-byte frame tag, then 3-byte sync 9D 01 2A, then LE dims.
        final o = 20 + 3 + 3;
        if (bytes.length >= o + 4) {
          final w = bytes[o] | (bytes[o + 1] << 8);
          final h = bytes[o + 2] | (bytes[o + 3] << 8);
          return ImageSize(w & 0x3FFF, h & 0x3FFF);
        }
      }
      return null;
    }
    return null;
  } catch (_) {
    return null;
  }
}
