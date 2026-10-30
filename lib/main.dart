import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'services/accent_store.dart';
import 'services/avdb_adapter.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'services/app_debug_log.dart';
import 'services/app_icon_service.dart';
import 'services/browser_view_store.dart';
import 'services/display_refresh_rate.dart';
import 'services/download_manager.dart';
import 'services/entitlements.dart';
import 'services/image_cache_service.dart';
import 'services/language_service.dart';
import 'services/metadata_provider_adapter.dart';
import 'services/r18dev_adapter.dart';
import 'services/layout_store.dart';
import 'services/font_store.dart';
import 'services/libsmb2_object_code.dart';
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
  // List / Grid choice for the network browsers.
  unawaited(BrowserViewStore.load());
  // Reconciles the launcher icon with the platform on every start and heals
  // the stored preference if a toggle was interrupted (issue #23).
  unawaited(AppIconService.instance.load());
  unawaited(DownloadManager.instance.init());
  unawaited(ImageCacheService.instance.init());
  // libsmb2 is LGPL-2.1 and is linked statically into the iOS app, so its
  // object code has to accompany the app (LGPL-2.1 section 6(a)). Copy it into
  // the Documents directory at startup so it is reachable through the Files
  // app even if the user never opens the licenses screen. Fire-and-forget:
  // it is a legal formality, not something the UI waits for.
  unawaited(LibSmb2ObjectCode.install());
  // StoreKit entitlement + 7-day trial state (iOS-only monetization; Android
  // stays permanently advanced — see Entitlements). Safe to run everywhere.
  unawaited(Entitlements.instance.init());
  // External metadata providers (issue #46 part 2). Registered here so the
  // Settings "External" segment appears as soon as an adapter exists; the
  // registry is inert until a provider is enabled.
  //
  // r18.dev is registered FIRST on purpose (issue #52): it is the richer of
  // the two for adult titles (uncensored title, studio, gallery) and it is
  // keyed by the catalogue code in the file name, so it is the better first
  // answer for a JAV file. AVDb still answers anything r18.dev does not
  // (it can search by name, r18.dev only by code), and either provider can be
  // turned off on its own.
  MetadataProviderRegistry.instance.register(R18DevAdapter.instance);
  MetadataProviderRegistry.instance.register(AvdbAdapter.instance);
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
