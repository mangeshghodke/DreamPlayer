import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One saved set of picture adjustments (brightness / contrast / saturation /
/// gamma, each in the shared −100…100 slider range, 0 = neutral).
///
/// Profiles are engine-agnostic: the MPV panel applies all four via mpv
/// properties; the Media3 panel applies brightness/contrast/saturation via
/// GL effects and ignores gamma (Media3 has no gamma effect). That asymmetry
/// is deliberate — a profile saved on one engine still applies its applicable
/// subset on the other instead of refusing to load.
@immutable
class PictureProfile {
  const PictureProfile({
    required this.name,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.gamma = 0,
  });

  final String name;
  final double brightness;
  final double contrast;
  final double saturation;
  final double gamma;

  static const double min = -100;
  static const double max = 100;

  double _clamp(double v) => v.clamp(min, max).toDouble();

  PictureProfile normalized() => PictureProfile(
        name: name,
        brightness: _clamp(brightness),
        contrast: _clamp(contrast),
        saturation: _clamp(saturation),
        gamma: _clamp(gamma),
      );

  /// True when every adjustment is neutral — applying such a profile is a
  /// no-op (and on Media3 must clear the GL effect pipeline).
  bool get isNeutral =>
      brightness == 0 && contrast == 0 && saturation == 0 && gamma == 0;

  Map<String, dynamic> toJson() => {
        'name': name,
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'gamma': gamma,
      };

  factory PictureProfile.fromJson(Map<dynamic, dynamic> json) {
    double asDouble(Object? v) => v is num ? v.toDouble() : 0;
    return PictureProfile(
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Profile',
      brightness: asDouble(json['brightness']),
      contrast: asDouble(json['contrast']),
      saturation: asDouble(json['saturation']),
      gamma: asDouble(json['gamma']),
    ).normalized();
  }

  @override
  bool operator ==(Object other) =>
      other is PictureProfile &&
      other.name == name &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.gamma == gamma;

  @override
  int get hashCode => Object.hash(name, brightness, contrast, saturation, gamma);
}

/// Persisted list of named [PictureProfile]s (`dreamplayer.pictureProfiles`).
/// Shared by the MPV and Media3 picture panels so a profile saved in one
/// engine can be applied in the other.
class PictureProfileStore extends ChangeNotifier {
  PictureProfileStore._();

  static final PictureProfileStore instance = PictureProfileStore._();

  static const String prefsKey = 'dreamplayer.pictureProfiles';

  static const int maxProfiles = 24;

  List<PictureProfile> _profiles = const [];

  List<PictureProfile> get profiles => List.unmodifiable(_profiles);

  bool get isLoaded => _loaded;
  bool _loaded = false;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) {
        _profiles = const [];
      } else {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _profiles = decoded
              .whereType<Map>()
              .map(PictureProfile.fromJson)
              .toList();
        } else {
          _profiles = const [];
        }
      }
    } catch (_) {
      _profiles = const [];
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefsKey,
        jsonEncode(_profiles.map((p) => p.toJson()).toList()),
      );
    } catch (_) {
      // A profile store must never break playback — persistence is best-effort.
    }
  }

  /// Saves [profile] under [profile.name], replacing any existing profile with
  /// the same name (case-insensitive). Returns false when the name is empty
  /// or the store is full and the name is new.
  Future<bool> save(PictureProfile profile) async {
    final p = profile.normalized();
    if (p.name.isEmpty) return false;
    final lower = p.name.toLowerCase();
    final next =
        _profiles.where((e) => e.name.toLowerCase() != lower).toList();
    if (next.length >= maxProfiles &&
        !_profiles.any((e) => e.name.toLowerCase() == lower)) {
      return false;
    }
    next.add(p);
    _profiles = next;
    notifyListeners();
    await _persist();
    return true;
  }

  /// Removes the profile named [name] (case-insensitive). Returns true when
  /// something was removed.
  Future<bool> remove(String name) async {
    final lower = name.toLowerCase();
    final before = _profiles.length;
    _profiles =
        _profiles.where((e) => e.name.toLowerCase() != lower).toList();
    if (_profiles.length == before) return false;
    notifyListeners();
    await _persist();
    return true;
  }

  PictureProfile? find(String name) {
    final lower = name.toLowerCase();
    for (final p in _profiles) {
      if (p.name.toLowerCase() == lower) return p;
    }
    return null;
  }

  @visibleForTesting
  void resetForTest() {
    _profiles = const [];
    _loaded = false;
  }
}
