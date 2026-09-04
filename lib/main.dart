import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'services/app_preferences.dart';
import 'services/display_refresh_rate.dart';
import 'utils/tv_helper.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPreferencesController.instance.load();
  await useNativeDisplayRefreshRate();
  unawaited(initTvMode());
  runApp(const DreamPlayerApp());
}
