/// A video entry discovered by the background MediaStore scanner.
class LibraryVideo {
  const LibraryVideo({
    required this.id,
    required this.path,
    required this.title,
    this.duration = 0,
    this.width = 0,
    this.height = 0,
    this.sizeBytes = 0,
    this.dateAdded = 0,
    this.mimeType = '',
  });

  /// MediaStore `_ID`.
  final int id;

  /// Absolute file path (`_DATA` column).
  final String path;

  /// Display name (`_DISPLAY_NAME`), cleaned of extension.
  final String title;

  /// Duration in milliseconds.
  final int duration;

  /// Video width in pixels.
  final int width;

  /// Video height in pixels.
  final int height;

  /// File size in bytes.
  final int sizeBytes;

  /// `DATE_ADDED` (epoch seconds).
  final int dateAdded;

  /// MIME type (e.g. `video/mp4`).
  final String mimeType;

  String get resolution {
    if (width <= 0 || height <= 0) return '';
    return '${width}x$height';
  }

  /// Best-guess label from pixel height (e.g. "1080p").
  String get resolutionLabel {
    if (height <= 0) return '';
    if (height >= 2160) return '4K';
    if (height >= 1440) return '1440p';
    if (height >= 1080) return '1080p';
    if (height >= 720) return '720p';
    if (height >= 480) return '480p';
    if (height >= 360) return '360p';
    return '${height}p';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'title': title,
        'duration': duration,
        'width': width,
        'height': height,
        'sizeBytes': sizeBytes,
        'dateAdded': dateAdded,
        'mimeType': mimeType,
      };

  factory LibraryVideo.fromJson(Map<String, dynamic> json) => LibraryVideo(
        id: (json['id'] as num?)?.toInt() ?? 0,
        path: json['path'] as String? ?? '',
        title: json['title'] as String? ?? '',
        duration: (json['duration'] as num?)?.toInt() ?? 0,
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        dateAdded: (json['dateAdded'] as num?)?.toInt() ?? 0,
        mimeType: json['mimeType'] as String? ?? '',
      );
}
