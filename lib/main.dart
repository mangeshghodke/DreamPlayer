import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'services/accent_store.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'services/app_debug_log.dart';
import 'services/display_refresh_rate.dart';
import 'services/download_manager.dart';
import 'services/entitlements.dart';
import 'services/image_cache_service.dart';
import 'services/language_service.dart';
import 'services/layout_store.dart';
import 'services/font_store.dart';
import 'utils/tv_helper.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await useNativeDisplayRefreshRate();
  unawaited(initTvMode());
  unawaited(LanguageService.instance.init());
  // Persisted accent colour + library layout (issue #34).
  unawaited(AccentStore.load());
  unawaited(LayoutStore.load());
  unawaited(FontStore.load());
  unawaited(DownloadManager.instance.init());
  unawaited(ImageCacheService.instance.init());
  // StoreKit entitlement + 7-day trial state (iOS-only monetization; Android
  // stays permanently advanced — see Entitlements). Safe to run everywhere.
  unawaited(Entitlements.instance.init());
  // Write a boot line FIRST, before any screen can fail. Without it, "no
  // app_debug.log in Files" is ambiguous: it cannot tell a broken writer from
  // markers that simply never fired, because the file is only created by the
  // first write. This is the Dart mirror of SBMLog.boot().
  //
  // Deliberately plugin-free: the first mark must not wait on a platform
  // channel that may not be registered yet.
  AppDebugLog.mark('app_debug: boot');
  unawaited(_logBoot());
  runApp(const DreamPlayerApp());
}

/// Writes the boot line into `app_debug.log`, stamped with the real build
/// number so a shared log identifies which build produced it — the same thing
/// `SBMLog.boot()` does for `smb_debug.log`.
Future<void> _logBoot() async {
  var version = 'unknown';
  try {
    final info = await PackageInfo.fromPlatform();
    version = '${info.version}+${info.buildNumber}';
  } catch (_) {}
  AppDebugLog.mark('app_debug: started (build $version)');
}
