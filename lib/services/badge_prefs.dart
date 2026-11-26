import 'package:shared_preferences/shared_preferences.dart';

/// Which on-screen badge categories the user wants to see during playback.
/// Each category is a checkbox under the "On-screen badges" toggle in
/// Settings → Player. The player reads these to filter the chip row.
class BadgePrefs {
  BadgePrefs._();

  static const _kEnabled = 'badge_enabled';
  // Format badges
  static const _kHdr = 'badge_hdr';
  static const _kAudio = 'badge_audio';
  static const _kResolution = 'badge_resolution';
  static const _kVideoCodec = 'badge_video_codec';
  // Playback state badges
  static const _kSpatialAudio = 'badge_spatial_audio';
  static const _kServerTranscode = 'badge_server_transcode';
  static const _kDecoder = 'badge_decoder';

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? true;
  static Future<bool> hdr() async =>
      (await SharedPreferences.getInstance()).getBool(_kHdr) ?? true;
  static Future<bool> audio() async =>
      (await SharedPreferences.getInstance()).getBool(_kAudio) ?? true;
  // Resolution / video codec / decoder default ON (issue #71): the badge
  // row is meant to read "4K HDR HEVC DTS 5.1" with the decoders below, so
  // those three are part of the default set, not opt-in extras.
  static Future<bool> resolution() async =>
      (await SharedPreferences.getInstance()).getBool(_kResolution) ?? true;
  static Future<bool> videoCodec() async =>
      (await SharedPreferences.getInstance()).getBool(_kVideoCodec) ?? true;
  static Future<bool> spatialAudio() async =>
      (await SharedPreferences.getInstance()).getBool(_kSpatialAudio) ?? true;
  static Future<bool> serverTranscode() async =>
      (await SharedPreferences.getInstance()).getBool(_kServerTranscode) ?? true;
  static Future<bool> decoder() async =>
      (await SharedPreferences.getInstance()).getBool(_kDecoder) ?? true;

  static Future<void> setEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kEnabled, v);
  static Future<void> setHdr(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kHdr, v);
  static Future<void> setAudio(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kAudio, v);
  static Future<void> setResolution(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kResolution, v);
  static Future<void> setVideoCodec(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kVideoCodec, v);
  static Future<void> setSpatialAudio(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kSpatialAudio, v);
  static Future<void> setServerTranscode(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kServerTranscode, v);
  static Future<void> setDecoder(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kDecoder, v);

  /// Returns all flags in one async call.
  static Future<BadgeFlags> load() async {
    final p = await SharedPreferences.getInstance();
    return BadgeFlags(
      enabled: p.getBool(_kEnabled) ?? true,
      hdr: p.getBool(_kHdr) ?? true,
      audio: p.getBool(_kAudio) ?? true,
      resolution: p.getBool(_kResolution) ?? true,
      videoCodec: p.getBool(_kVideoCodec) ?? true,
      spatialAudio: p.getBool(_kSpatialAudio) ?? true,
      serverTranscode: p.getBool(_kServerTranscode) ?? true,
      decoder: p.getBool(_kDecoder) ?? true,
    );
  }
}

class BadgeFlags {
  const BadgeFlags({
    required this.enabled,
    required this.hdr,
    required this.audio,
    required this.resolution,
    required this.videoCodec,
    required this.spatialAudio,
    required this.serverTranscode,
    required this.decoder,
  });

  final bool enabled;
  final bool hdr;
  final bool audio;
  final bool resolution;
  final bool videoCodec;
  final bool spatialAudio;
  final bool serverTranscode;
  final bool decoder;
}
