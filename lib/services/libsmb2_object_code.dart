import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Where libsmb2's LGPL-2.1 relinking material ended up, or why it did not.
///
/// libsmb2 is licensed under the GNU Lesser General Public License v2.1.
///
/// * On **iOS** the library is linked STATICALLY into the app binary, so
///   LGPL-2.1 §6(a) applies: the object code of the library has to accompany
///   the work, so the user can modify libsmb2 and relink. The iOS build
///   packages the compiled object files, the sources, the license and the
///   relinking instructions into a zip (`ios/libsmb2_build.sh`), and this
///   service copies that zip into the app's Documents directory, where the
///   Files app exposes it under "On My iPad → DreamPlayer".
/// * On **Android** the same sources are compiled into a separate shared
///   library (`libsmb2jni.so`) that is installed alongside the app and can be
///   replaced by the user with an interface-compatible build, which is the
///   §6(b) mechanism, so no object code has to travel with the APK.
class LibSmb2ObjectCode {
  const LibSmb2ObjectCode._({this.path, this.reason});

  /// Asset key of the packaged archive (see `pubspec.yaml`).
  static const String assetPath = 'assets/libsmb2-objects/libsmb2-objects.zip';

  /// Name of the file inside the app's Documents directory.
  static const String fileName = 'libsmb2-objects.zip';

  /// Absolute path of the archive once it has been installed, or null.
  final String? path;

  /// Human-readable explanation of why the archive is not available.
  final String? reason;

  bool get available => path != null;

  /// Copies the packaged archive into the app's Documents directory.
  ///
  /// Safe to call repeatedly: an existing archive is left alone. Never throws
  /// — a missing archive is a licensing problem worth reporting in the UI,
  /// not a crash.
  static Future<LibSmb2ObjectCode> install() async {
    if (!Platform.isIOS) {
      return const LibSmb2ObjectCode._(
        reason: 'libsmb2 ships as a separate shared library on Android, so it '
            'can be replaced with a modified build without relinking.',
      );
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      final target = File('${docs.path}${Platform.pathSeparator}$fileName');
      if (await target.exists() && await target.length() > 0) {
        return LibSmb2ObjectCode._(path: target.path);
      }
      final data = await rootBundle.load(assetPath);
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return LibSmb2ObjectCode._(path: target.path);
    } catch (e) {
      return LibSmb2ObjectCode._(
        reason: 'The libsmb2 object code is not included in this build '
            '($e).',
      );
    }
  }
}
