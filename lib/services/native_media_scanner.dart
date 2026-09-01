import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../models/library_video.dart';

/// Dart wrapper around the native `MediaScanner` channel.  Provides a single
/// `scanAll()` method that returns every video on the device from MediaStore.
class NativeMediaScanner {
  NativeMediaScanner._();
  static final NativeMediaScanner instance = NativeMediaScanner._();

  static const _channel = MethodChannel('dreamplayer/media_scanner');

  /// Queries MediaStore for all videos.  Returns an empty list on iOS (the
  /// native side only exists on Android) or on permission denial.
  Future<List<LibraryVideo>> scanAll() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List>('scanAll');
      if (raw == null) return const [];
      return raw
          .map((e) => LibraryVideo.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } on PlatformException {
      return const [];
    }
  }
}
