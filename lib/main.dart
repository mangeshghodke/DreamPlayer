import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'services/accent_store.dart';
import 'services/display_refresh_rate.dart';
import 'services/download_manager.dart';
import 'services/entitlements.dart';
import 'services/image_cache_service.dart';
import 'services/language_service.dart';
import 'services/layout_store.dart';
import 'utils/tv_helper.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await useNativeDisplayRefreshRate();
  unawaited(initTvMode());
  unawaited(LanguageService.instance.init());
  // Persisted accent colour + library layout (issue #34).
  unawaited(AccentStore.load());
  unawaited(LayoutStore.load());
  unawaited(DownloadManager.instance.init());
  unawaited(ImageCacheService.instance.init());
  // StoreKit entitlement + 7-day trial state (iOS-only monetization; Android
  // stays permanently advanced — see Entitlements). Safe to run everywhere.
  unawaited(Entitlements.instance.init());
  runApp(const DreamPlayerApp());
}
