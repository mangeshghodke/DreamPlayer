import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The launcher icon variants shipped with the app (issue #23).
enum AppIconStyle {
  /// The shipped DreamPlayer icon: logo + "DreamPlayer" wordmark.
  defaultIcon,

  /// The logo alone, original colours. Android already prints the app name
  /// under the icon, so the wordmark is redundant there.
  markOnly,

  /// The logo recoloured red.
  red,

  /// The logo recoloured green.
  green,

  /// The logo recoloured cyan.
  cyan,
}

/// Wire names shared with `IconSwitcher.kt` and iOS `CFBundleAlternateIcons`.
extension AppIconStyleNative on AppIconStyle {
  String get nativeName => switch (this) {
    AppIconStyle.defaultIcon => 'default',
    AppIconStyle.markOnly => 'mark',
    AppIconStyle.red => 'red',
    AppIconStyle.green => 'green',
    AppIconStyle.cyan => 'cyan',
  };

  /// Name of the iOS alternate icon bundle, or null for the primary one.
  String? get iosAlternateIconName => switch (this) {
    AppIconStyle.defaultIcon => null,
    AppIconStyle.markOnly => 'AppIconMark',
    AppIconStyle.red => 'AppIconRed',
    AppIconStyle.green => 'AppIconGreen',
    AppIconStyle.cyan => 'AppIconCyan',
  };
}

extension AppIconStyleLabel on AppIconStyle {
  String get label => switch (this) {
    AppIconStyle.defaultIcon => 'Default',
    AppIconStyle.markOnly => 'Logo only',
    AppIconStyle.red => 'Red',
    AppIconStyle.green => 'Green',
    AppIconStyle.cyan => 'Cyan',
  };

  String get description => switch (this) {
    AppIconStyle.defaultIcon => 'The original DreamPlayer icon',
    AppIconStyle.markOnly => 'Just the logo, without the "DreamPlayer" text',
    AppIconStyle.red => 'The logo in red',
    AppIconStyle.green => 'The logo in green',
    AppIconStyle.cyan => 'The logo in cyan',
  };
}

/// Chooses the launcher icon.
///
/// There is no cross-platform "set icon" API, so each platform does its own
/// thing behind [CHANNEL]:
///
///  * **Android** toggles `activity-alias` entries with
///    `PackageManager.setComponentEnabledSetting()`. The aliases carry a full
///    copy of MainActivity's intent filters, because disabling a component also
///    stops it receiving "Open with" intents.
///  * **iOS** uses `UIApplication.setAlternateIconName()`, which is
///    first-class and supported.
///
/// Launchers cache icons aggressively, so the new icon may take a moment to
/// appear (and on some launchers only after it restarts).
class AppIconService extends ChangeNotifier {
  AppIconService._();

  static final AppIconService instance = AppIconService._();

  static const String channel = 'dreamplayer/appicon';
  static const String _prefKey = 'dreamplayer.appIcon';

  AppIconStyle _style = AppIconStyle.defaultIcon;
  AppIconStyle get style => _style;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;
  bool get _isIOS => !kIsWeb && Platform.isIOS;
  bool get _supported => _isAndroid || _isIOS;

  static const MethodChannel _channel = MethodChannel(channel);

  /// Reads the platform's actual state and heals the stored preference.
  ///
  /// The platform is the authority, not the pref: the pref records intent, the
  /// package manager records reality. They can disagree if a toggle was
  /// interrupted, so the native state wins and the pref is corrected.
  Future<void> load() async {
    if (!_supported) return;

    String? variant;
    try {
      variant = await _channel.invokeMethod<String>('currentVariant');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    if (variant == null) return;

    final resolved = _fromNative(variant);
    _style = resolved;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_prefKey) != resolved.name) {
      await prefs.setString(_prefKey, resolved.name);
    }
  }

  /// Applies [style] to the launcher. Returns false if the platform refused.
  Future<bool> apply(AppIconStyle style) async {
    if (!_supported) return false;
    try {
      await _channel.invokeMethod<bool>('applyVariant', {
        'variant': style.nativeName,
      });
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
    _style = style;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, style.name);
    return true;
  }

  static AppIconStyle _fromNative(String name) => switch (name) {
    'mark' => AppIconStyle.markOnly,
    'red' => AppIconStyle.red,
    'green' => AppIconStyle.green,
    'cyan' => AppIconStyle.cyan,
    _ => AppIconStyle.defaultIcon,
  };
}