import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';
import 'subtitle_style.dart';

const String exoPlayerViewType = 'dreamplayer/exo_player';

/// How the video fills the playback view.
///
/// Maps to Media3 `AspectRatioFrameLayout` resize modes on Android and AVPlayer
/// `videoGravity` on iOS. Matches Nova Video Player's "Format" menu options:
/// Original, Fullscreen, Stretched, Crop, 4:3, 16:9, 1.85:1, 2.39:1.
enum VideoFitMode {
  /// Source aspect ratio (letterbox on the screen).
  fit(0),

  /// Fullscreen: keep display dimensions, ignore AR (remove black bars by
  /// cropping). Equivalent to Nova's `FULL_SCREEN`.
  fullscreen(1),

  /// Crop to fill: fills the view, keeps aspect, cuts off overflow.
  /// Equivalent to Media3 `RESIZE_MODE_ZOOM`.
  crop(2),

  /// Stretch: distorts the frame to fill the view exactly.
  stretch(3),

  /// Crop to a fixed 4:3 box.
  ratio4x3(4),

  /// Crop to a fixed 16:9 box.
  ratio16x9(5),

  /// Crop to a fixed 1.85:1 box (cinema / US widescreen).
  ratio185(6),

  /// Crop to a fixed 2.39:1 box (CinemaScope / anamorphic).
  ratio239(7);

  const VideoFitMode(this.value);

  /// Stable id sent over the method channel.
  final int value;

  String get label => switch (this) {
    fit => 'Fit',
    fullscreen => 'Fullscreen',
    crop => 'Crop to screen',
    stretch => 'Stretch to screen',
    ratio4x3 => '4:3',
    ratio16x9 => '16:9',
    ratio185 => '1.85:1',
    ratio239 => '2.39:1',
  };

  /// Floating-point aspect ratio for the fixed-ratio modes, used by
  /// `ForcedAspectPlayerView` to letterbox the source. Null for the
  /// non-fixed modes (fit/crop/stretch/fullscreen are handled by the
  /// native resize modes directly).
  double? get fixedAspect => switch (this) {
    ratio4x3 => 4.0 / 3.0,
    ratio16x9 => 16.0 / 9.0,
    ratio185 => 1.85,
    ratio239 => 2.39,
    _ => null,
  };

  static VideoFitMode fromValue(int? value) => VideoFitMode.values.firstWhere(
    (m) => m.value == value,
    orElse: () => VideoFitMode.fit,
  );
}

/// Persists the user's chosen [VideoFitMode] across playback sessions.
class FitModeStore {
  FitModeStore._();

  static const String _prefsKey = 'dreamplayer.fitMode';

  static Future<VideoFitMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    return VideoFitMode.fromValue(prefs.getInt(_prefsKey));
  }

  static Future<void> save(VideoFitMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey, mode.value);
  }
}

/// Persists the user's preferred playback speed (applied on every open).
class PlaybackSpeedStore {
  PlaybackSpeedStore._();

  static const String _prefsKey = 'dreamplayer.playbackSpeed';

  static Future<double> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_prefsKey) ?? 1.0;
  }

  static Future<void> save(double speed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsKey, speed);
  }
}

/// Persists the volume boost factor (1.0 = off, 3.0 = +1500 mB).
class PlaybackBoostStore {
  PlaybackBoostStore._();

  static const String _prefsKey = 'dreamplayer.audioBoost';

  static Future<double> load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble(_prefsKey);
    if (v == null) return 1.0;
    return v.clamp(1.0, 3.0);
  }

  static Future<void> save(double boost) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsKey, boost.clamp(1.0, 3.0));
  }
}

/// Persists Night Mode (dynamic range compression).
class NightModeStore {
  NightModeStore._();

  static const String _prefsKey = 'dreamplayer.nightMode';

  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKey) ?? false;
  }

  static Future<void> save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, enabled);
  }
}

/// A single audio track exposed by the native ExoPlayer, for the track picker.
@immutable
class ExoAudioTrack {
  const ExoAudioTrack({
    required this.index,
    this.language,
    this.label,
    this.codecs,
    this.mime,
    this.channels = 0,
    this.bitrate = 0,
    this.selected = false,
  });

  /// Flat index; the value to pass to [ExoPlayerController.selectAudioTrack].
  final int index;

  /// ISO-639 language code (e.g. `eng`).
  final String? language;

  /// Container-provided track name (e.g. `DTS-HD MA 5.1`, `Commentary`).
  /// Empty when the file has no named tracks.
  final String? label;
  final String? codecs;
  final String? mime;
  final int channels;
  final int bitrate;
  final bool selected;

  factory ExoAudioTrack.fromMap(Map<dynamic, dynamic> m) {
    int asInt(dynamic v) => v is num ? v.toInt() : 0;
    return ExoAudioTrack(
      index: asInt(m['index']),
      language: m['language'] as String?,
      label: m['label'] as String?,
      codecs: m['codecs'] as String?,
      mime: m['mime'] as String?,
      channels: asInt(m['channels']),
      bitrate: asInt(m['bitrate']),
      selected: m['selected'] == true,
    );
  }
}

/// A single subtitle track exposed by the native ExoPlayer, for the subtitle
/// picker. Covers both embedded container tracks (PGS, SRT-in-MKV, ...) and
/// sideloaded sidecar files.
@immutable
class ExoSubtitleTrack {
  const ExoSubtitleTrack({
    required this.index,
    this.language,
    this.label,
    this.codecs,
    this.mime,
    this.sideloaded = false,
    this.selected = false,
  });

  /// Flat index; the value to pass to [ExoPlayerController.selectSubtitleTrack].
  final int index;

  /// ISO-639 language code (e.g. `eng`).
  final String? language;

  /// Track name: the container-provided label, or the sidecar file's base
  /// name (e.g. `Show.S01E01.eng`). Empty when unnamed.
  final String? label;

  /// Codec string (e.g. `application/x-subrip`, `hdmv.pgs`). For sideloaded
  /// tracks this is the sidecar's original MIME type.
  final String? codecs;
  final String? mime;
  final bool sideloaded;
  final bool selected;

  factory ExoSubtitleTrack.fromMap(Map<dynamic, dynamic> m) {
    int asInt(dynamic v) => v is num ? v.toInt() : 0;
    return ExoSubtitleTrack(
      index: asInt(m['index']),
      language: m['language'] as String?,
      label: m['label'] as String?,
      codecs: m['codecs'] as String?,
      mime: m['mime'] as String?,
      sideloaded: m['sideloaded'] == true,
      selected: m['selected'] == true,
    );
  }
}

/// Snapshot of playback state pushed from the native ExoPlayer platform view.
@immutable
/// A container chapter (MKV `Chapters`), parsed natively on open.
@immutable
class ExoChapter {
  const ExoChapter({
    required this.title,
    required this.startMs,
    this.endMs,
  });

  final String title;
  final int startMs;
  final int? endMs;

  static ExoChapter fromMap(Map<dynamic, dynamic> m) => ExoChapter(
        title: m['title'] as String? ?? 'Chapter',
        startMs: m['startMs'] is num ? (m['startMs'] as num).toInt() : 0,
        endMs: m['endMs'] is num ? (m['endMs'] as num).toInt() : null,
      );
}

class ExoPlayerEvent {
  const ExoPlayerEvent({
    required this.state,
    required this.playing,
    required this.buffering,
    required this.ended,
    required this.positionMs,
    required this.durationMs,
    this.bufferedMs = 0,
    this.videoCodecs,
    this.videoMime,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.colorTransfer,
    this.isHdr10Plus = false,
    this.isHdr10 = false,
    this.audioCodecs,
    this.audioMime,
    this.audioChannels = 0,
    this.audioTracks = const [],
    this.selectedAudioTrack = -1,
    this.subtitleLabel,
    this.subtitleFormat,
    this.subtitleOn = false,
    this.subtitleTracks = const [],
    this.selectedSubtitleTrack = -1,
    this.error,
    this.errorMessage,
    this.errorCause,
    this.audioPassthrough = false,
    this.audioBoost = 1.0,
    this.nightMode = false,
    this.bassBoost = 0,
    this.spatialAudio = '',
    this.chapters = const [],
    this.videoDecoderName,
    this.isHwDecoder,
    this.inPip = false,
    this.sourceScheme = '',
  });

  final int state;
  final bool playing;
  final bool buffering;
  final bool ended;
  final int positionMs;
  final int durationMs;
  final int bufferedMs;
  final String? videoCodecs;
  final String? videoMime;
  final int videoWidth;
  final int videoHeight;
  final int? colorTransfer;

  /// True when the native side found ST 2094-40 (HDR10+) dynamic metadata in
  /// the video bitstream. Media3's format info can't tell HDR10+ from HDR10
  /// (both are PQ transfer), so this is a separate bitstream probe result.
  final bool isHdr10Plus;

  /// True when the native side found static HDR10 metadata (SEI payload
  /// types 137 = mastering display colour volume, 144 = content light level)
  /// in the video bitstream. This covers plain HDR10 files that omit the
  /// MKV Colour element — Media3's MatroskaExtractor doesn't populate
  /// `Format.colorInfo`, so this bitstream probe restores the correct
  /// HDR10 label and engages the headroom path.
  final bool isHdr10;
  final String? audioCodecs;
  final String? audioMime;
  final int audioChannels;
  final List<ExoAudioTrack> audioTracks;
  final int selectedAudioTrack;

  /// Auto-paired sideloaded subtitle, e.g. `Show.S01E01.eng` (null when the
  /// video has no paired subtitle file).
  final String? subtitleLabel;

  /// Subtitle file format name (e.g. `SRT`, `SSA/ASS`, `SAMI`, `MicroDVD`).
  final String? subtitleFormat;
  final bool subtitleOn;

  /// All subtitle tracks (embedded + sideloaded) exposed by the player.
  final List<ExoSubtitleTrack> subtitleTracks;
  final int selectedSubtitleTrack;
  final String? error;

  /// Native PlaybackException detail (message / cause) for a friendlier error
  /// surface than just the opaque error code name.
  final String? errorMessage;
  final String? errorCause;

  /// True when audio passthrough is active (encoded bitstream routed to
  /// HDMI output via AudioTrack passthrough mode).
  final bool audioPassthrough;

  /// Android platform Spatializer status: `on` (engaged on multichannel
  /// content), `available` (routing supports it, toggle off / stereo track),
  /// or `unavailable`. Empty before the first native event (iOS).
  final String spatialAudio;

  /// Bass boost level 0–3 (off/low/medium/high) from the native BassBoost.
  final int bassBoost;

  /// Volume boost factor (1.0–3.0) from the native LoudnessEnhancer.
  final double audioBoost;

  /// Night Mode flag (compressed dynamic range).
  final bool nightMode;

  /// Container chapters (MKV only, local files). Empty when the file has
  /// none or the source is a network stream.
  final List<ExoChapter> chapters;

  /// Video decoder component name (e.g. `c2.qti.hevc.decoder` = HW,
  /// `c2.android.avc.decoder` = SW). Null until the decoder is initialized.
  final String? videoDecoderName;

  /// True = hardware decoder, false = software, null = unknown yet.
  final bool? isHwDecoder;

  /// True while the activity is in picture-in-picture mode (Dart hides all
  /// overlay controls; only the video floats).
  final bool inPip;

  /// Lower-cased scheme of the current source URI: "file", "content", "http",
  /// "https", "ftp", "sftp", "dreamplayersmb", "dreamplayerwebdav", etc.
  /// Used by the ⓘ info sheet to label the source ("Local", "WebDAV",
  /// "Jellyfin", "SMB", …).
  final String sourceScheme;

  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);
  Duration get buffered => Duration(milliseconds: bufferedMs);

  static ExoPlayerEvent fromMap(Map<dynamic, dynamic> m) {
    int asInt(dynamic v, [int fallback = 0]) => v is num ? v.toInt() : fallback;
    return ExoPlayerEvent(
      state: asInt(m['state']),
      playing: m['playing'] == true,
      buffering: m['buffering'] == true,
      ended: m['ended'] == true,
      positionMs: asInt(m['positionMs']),
      durationMs: asInt(m['durationMs']),
      bufferedMs: asInt(m['bufferedMs']),
      videoCodecs: m['videoCodecs'] as String?,
      videoMime: m['videoMime'] as String?,
      videoWidth: asInt(m['videoWidth']),
      videoHeight: asInt(m['videoHeight']),
      colorTransfer: m['colorTransfer'] is num
          ? (m['colorTransfer'] as num).toInt()
          : null,
      isHdr10Plus: m['isHdr10Plus'] == true,
      isHdr10: m['isHdr10'] == true,
      audioCodecs: m['audioCodecs'] as String?,
      audioMime: m['audioMime'] as String?,
      audioChannels: asInt(m['audioChannels']),
      audioTracks: (m['audioTracks'] as List? ?? const [])
          .map((e) => ExoAudioTrack.fromMap(e as Map<dynamic, dynamic>))
          .toList(),
      selectedAudioTrack: asInt(m['selectedAudioTrack'], -1),
      subtitleLabel: m['subtitleLabel'] as String?,
      subtitleFormat: m['subtitleFormat'] as String?,
      subtitleOn: m['subtitleOn'] == true,
      subtitleTracks: (m['subtitleTracks'] as List? ?? const [])
          .map((e) => ExoSubtitleTrack.fromMap(e as Map<dynamic, dynamic>))
          .toList(),
      selectedSubtitleTrack: asInt(m['selectedSubtitleTrack'], -1),
      error: m['error'] as String?,
      errorMessage: m['errorMessage'] as String?,
      errorCause: m['errorCause'] as String?,
      audioPassthrough: m['audioPassthrough'] == true,
      spatialAudio: m['spatialAudio'] as String? ?? '',
      audioBoost: m['audioBoost'] is num ? (m['audioBoost'] as num).toDouble().clamp(1.0, 3.0) : 1.0,
      nightMode: m['nightMode'] == true,
      bassBoost: asInt(m['bassBoost'], 0),
      chapters: (m['chapters'] as List? ?? const [])
          .map((e) => ExoChapter.fromMap(e as Map<dynamic, dynamic>))
          .toList(),
      videoDecoderName: m['videoDecoderName'] as String?,
      isHwDecoder: m['isHwDecoder'] as bool?,
      inPip: m['inPip'] == true,
      sourceScheme: m['sourceScheme'] as String? ?? '',
    );
  }
}

/// Common playback-control surface implemented by the in-app
/// [ExoPlayerController]. The player screen drives it on every platform
/// (phones, tablets, Android TV / Fire TV).
abstract class PlaybackController {
  Stream<ExoPlayerEvent> get events;

  ExoPlayerEvent? get latest;

  Future<void> open(
    String path, {
    String? uri,
    String? subtitleUri,
    int? startPositionMs,
    Map<String, String>? httpHeaders,
    bool allowSelfSigned = false,
    String? resumeKey,
    String? title,
    List<VideoExternalSub>? externalSubtitles,
    String? decoderMode,
    String? readingLanguage,
  });

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(Duration position);

  Future<void> setVolume(double volume);

  Future<void> setMuted(bool muted);

  Future<void> selectAudioTrack(int index);

  Future<void> selectSubtitleTrack(int index);

  /// Applies the user's subtitle appearance natively (size/color/background/
  /// outline + cue delay).
  Future<void> setSubtitleStyle(SubtitleStyle style);

  Future<void> setSubtitles(bool on);

  Future<void> setFitMode(VideoFitMode mode);

  /// Sets the playback speed (0.25–4.0). Persists across seeks; Dart
  /// re-applies it on every open.
  Future<void> setSpeed(double speed);

  /// Native repeat loop for the current media item: 0 = off, 1 = repeat one,
  /// 2 = repeat all (meaningless for a single item; Dart drives folder loops).
  /// Android maps to Media3 `Player.setRepeatMode`; iOS is a no-op (the Dart
  /// ended-handler restarts the session there).
  Future<void> setRepeatMode(int mode);

  /// Manual A/V sync: shifts audio relative to video. Positive = audio
  /// later. Android retunes a PCM AudioProcessor live; iOS is a no-op
  /// (AetherEngine exposes no audio-offset hook yet — UI hidden there).
  Future<void> setAudioDelay(int ms);

  /// Enters picture-in-picture (Android only; no-op elsewhere or when
  /// paused). Auto-entry on HOME is native (onUserLeaveHint).
  Future<void> enterPip();

  /// Sets the display brightness (0.0 = dim, 1.0 = max). Per-app; reverts on
  /// player close on both platforms. Pass -1 to restore system default.
  Future<void> setBrightness(double brightness);

  /// Returns the current screen brightness (0.0–1.0).
  Future<double> getBrightness();

  /// Sets the system media volume (0.0–1.0). On Android this is
  /// AudioManager STREAM_MUSIC; on iOS this uses MPVolumeView.
  Future<void> setSystemVolume(double volume);

  /// Returns the current system media volume normalised to 0.0–1.0.
  Future<double> getSystemVolume();

  /// Volume boost factor (1.0 = unity, 3.0 = ~+1500 mB via LoudnessEnhancer).
  Future<void> setAudioBoost(double boost);

  /// Night Mode — dynamic range compression / loudness normalisation.
  Future<void> setNightMode(bool enabled);

  /// Sets the bass boost level (0 off – 3 high); Android only.
  Future<void> setBassBoost(int level);

  /// Pinch-to-zoom crop: scales the video surface around its center
  /// (1.0 = fit, up to ~3.0 = zoomed in). Transient per session.
  Future<void> setZoom(double scale);

  Future<ExoPlayerEvent?> getState();

  /// "Play with external app": hands the current video to another installed
  /// player via an ACTION_VIEW chooser (Android only; no-op elsewhere).
  /// [path] / [uri] / [resumeKey] select the playable source.
  Future<bool> playExternal({String? path, String? uri});

  Future<void> dispose();
}

/// Dart-side handle to the native ExoPlayer platform view.
///
/// Create a [controller] and pass it to an [ExoPlayerView]; after the platform
/// view is created the controller's channels become live. Commands issued
/// before the platform view attaches (e.g. [open] from a screen's `initState`)
/// are queued and flushed once the channel exists. Listen on [events] for
/// playback state, or query [latest] for the most recent snapshot.
class ExoPlayerController implements PlaybackController {
  final _events = StreamController<ExoPlayerEvent>.broadcast();

  MethodChannel? _method;
  ExoPlayerEvent? _latest;
  final List<(String, Map<String, dynamic>?)> _pending = [];

  @override
  ExoPlayerEvent? get latest => _latest;

  /// Stream of playback state snapshots (roughly 250 ms while playing).
  @override
  Stream<ExoPlayerEvent> get events => _events.stream;

  void _attach(int viewId) {
    final method = MethodChannel('dreamplayer/exo_$viewId');
    _method = method;
    EventChannel(
      'dreamplayer/exo_events_$viewId',
    ).receiveBroadcastStream().listen((raw) {
      if (raw is! Map) return;
      final event = ExoPlayerEvent.fromMap(raw);
      _latest = event;
      if (!_events.isClosed) _events.add(event);
    });
    for (final (name, args) in _pending) {
      method.invokeMethod(name, args);
    }
    _pending.clear();
  }

  @override
  Future<void> open(
    String path, {
    String? uri,
    String? subtitleUri,
    int? startPositionMs,
    Map<String, String>? httpHeaders,
    bool allowSelfSigned = false,
    String? resumeKey,
    String? title,
    List<VideoExternalSub>? externalSubtitles,
    String? decoderMode,
    String? readingLanguage,
  }) => _send('open', {
    if (uri != null && uri.isNotEmpty) 'uri': uri else 'path': path,
    if (path.isNotEmpty) 'path': path,
    if (subtitleUri != null && subtitleUri.isNotEmpty)
      'subtitleUri': subtitleUri,
    if (startPositionMs != null && startPositionMs > 0)
      'startPositionMs': startPositionMs,
    if (httpHeaders != null && httpHeaders.isNotEmpty) 'headers': httpHeaders,
    if (allowSelfSigned) 'allowSelfSigned': true,
    if (resumeKey != null && resumeKey.isNotEmpty) 'resumeKey': resumeKey,
    if (title != null && title.isNotEmpty) 'title': title,
    if (externalSubtitles != null && externalSubtitles.isNotEmpty)
      'externalSubtitles':
          externalSubtitles.map((s) => s.toJson()).toList(),
    if (decoderMode != null && decoderMode.isNotEmpty)
      'decoderMode': decoderMode,
    if (readingLanguage != null && readingLanguage.isNotEmpty)
      'readingLanguage': readingLanguage,
  });

  @override
  Future<void> play() => _send('play');

  @override
  Future<void> pause() => _send('pause');

  /// Queries the native player's current state directly, instead of relying on
  /// the last pushed event. Returns null when the platform view isn't attached
  /// (e.g. mid background/foreground surface recreation) — callers can retry.
  @override
  Future<ExoPlayerEvent?> getState() async {
    final channel = _method;
    if (channel == null) return _latest;
    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>('getState');
      if (raw is Map) {
        final event = ExoPlayerEvent.fromMap(raw);
        _latest = event;
        return event;
      }
    } catch (_) {
      // Channel torn down while the view is being recreated; not attached yet.
      return null;
    }
    return _latest;
  }

  /// "Play with external app" — Android only. iOS/mpv have no equivalent
  /// (see the sandbox limitation in AGENTS.md).
  @override
  Future<bool> playExternal({String? path, String? uri}) async {
    final channel = _method;
    if (channel == null) return false;
    try {
      final ok = await channel.invokeMethod<bool>('playExternal', {
        if (path != null && path.isNotEmpty) 'path': path,
        if (uri != null && uri.isNotEmpty) 'uri': uri,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> seekTo(Duration position) =>
      _send('seekTo', {'positionMs': position.inMilliseconds});

  @override
  Future<void> setVolume(double volume) =>
      _send('setVolume', {'volume': volume});

  @override
  Future<void> setMuted(bool muted) => _send('setMuted', {'muted': muted});

  @override
  Future<void> selectAudioTrack(int index) =>
      _send('setAudioTrack', {'index': index});

  @override
  Future<void> setSubtitles(bool on) => _send('setSubtitles', {'on': on});

  @override
  Future<void> selectSubtitleTrack(int index) =>
      _send('setSubtitleTrack', {'index': index});

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) =>
      _send('setSubtitleStyle', style.toChannelArgs());

  /// Sets how the video fills the view (fit/crop/stretch/fixed ratio).
  @override
  Future<void> setFitMode(VideoFitMode mode) =>
      _send('setResizeMode', {'mode': mode.value});

  @override
  Future<void> setSpeed(double speed) =>
      _send('setSpeed', {'speed': speed.clamp(0.25, 4.0)});

  @override
  Future<void> setRepeatMode(int mode) =>
      _send('setRepeatMode', {'mode': mode});

  @override
  Future<void> setAudioDelay(int ms) => _send('setAudioDelay', {'ms': ms});

  @override
  Future<void> enterPip() => _send('enterPip');

  @override
  Future<void> setBrightness(double brightness) =>
      _send('setBrightness', {'brightness': brightness});

  @override
  Future<double> getBrightness() async {
    final channel = _method;
    if (channel == null) return 0.5;
    try {
      final raw = await channel.invokeMethod<double>('getBrightness');
      return (raw ?? 0.5).clamp(0.0, 1.0);
    } catch (_) {
      return 0.5;
    }
  }

  @override
  Future<void> setSystemVolume(double volume) =>
      _send('setSystemVolume', {'volume': volume});

  @override
  Future<double> getSystemVolume() async {
    final channel = _method;
    if (channel == null) return 1.0;
    try {
      final raw = await channel.invokeMethod<double>('getSystemVolume');
      return (raw ?? 1.0).clamp(0.0, 1.0);
    } catch (_) {
      return 1.0;
    }
  }

  @override
  Future<void> setAudioBoost(double boost) =>
      _send('setAudioBoost', {'boost': boost.clamp(1.0, 3.0)});

  @override
  Future<void> setNightMode(bool enabled) =>
      _send('setNightMode', {'enabled': enabled});

  @override
  Future<void> setBassBoost(int level) =>
      _send('setBassBoost', {'level': level.clamp(0, 3)});

  @override
  Future<void> setZoom(double scale) =>
      _send('setZoom', {'scale': scale.clamp(1.0, 3.0)});

  Future<void> disposeNative() => _send('dispose');

  Future<void> _send(String method, [Map<String, dynamic>? args]) {
    final channel = _method;
    if (channel == null) {
      _pending.add((method, args));
      return Future<void>.value();
    }
    try {
      // `MissingPluginException` is thrown on the returned future (not
      // synchronously) when the platform view is torn down during dispose.
      return channel.invokeMethod(method, args).catchError((Object _) {
        // Channel may be torn down during dispose; ignore.
      });
    } catch (_) {
      // Channel may be torn down during dispose; ignore.
      return Future<void>.value();
    }
  }

  @override
  Future<void> dispose() async {
    await disposeNative();
    await _events.close();
  }
}

/// Embeds the native playback engine platform view.
///
/// Android: the ExoPlayer/Media3 [PlayerView]'s internal `SurfaceView` is
/// rendered through Flutter's **hybrid composition** (`PlatformViewLink` +
/// `PlatformViewsService.initExpensiveAndroidView`) so the video surface keeps
/// its own SurfaceFlinger layer on the physical display — required for real
/// HDR / Dolby Vision output.
///
/// The default `AndroidView` widget uses Flutter's virtual-display + texture
/// composition: the SurfaceView is composited into a non-HDR virtual display
/// (`flutter-vd#1` in SurfaceFlinger), read back as a texture, and that
/// SDR-flattened texture is what reaches the panel. Real HDR is impossible
/// through that path — the PQ/HLG transfer and the BT.2020 dataspace are lost
/// before the display ever sees them, so HDR/DV content renders washed out
/// (verified on-device: the DV P8 `c884f7` SurfaceView composited as CLIENT
/// into `flutter-vd#1` with `HWC Support: dv=false`, while Just Player's same
/// file device-composited onto the HDR panel). Hybrid composition keeps the
/// SurfaceView as a real layer on the physical display, so the decoder's PQ
/// output goes straight to the HWC and the display tone-maps it natively.
///
/// iOS: AVPlayer-backed `AVPlayerLayer` (see `AvPlayerView.swift`), which also
/// renders on its own Core Animation layer so the display receives the native
/// HDR signal.
class ExoPlayerView extends StatelessWidget {
  const ExoPlayerView({super.key, required this.controller});

  final ExoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return UiKitView(
        viewType: exoPlayerViewType,
        onPlatformViewCreated: controller._attach,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    // This platform view is the single playback surface on every platform:
    // phones and Android TV / Fire TV alike use the same hybrid-composition
    // SurfaceView so true HDR/DV stays device-composited everywhere.
    return PlatformViewLink(
      viewType: exoPlayerViewType,
      surfaceFactory:
          (BuildContext context, PlatformViewController controller) {
            return AndroidViewSurface(
              controller: controller as AndroidViewController,
              gestureRecognizers:
                  const <Factory<OneSequenceGestureRecognizer>>{},
              hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            );
          },
      onCreatePlatformView: (PlatformViewCreationParams params) {
        final AndroidViewController nativeController =
            PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: params.viewType,
              layoutDirection: TextDirection.ltr,
            );
        nativeController
          ..addOnPlatformViewCreatedListener(controller._attach)
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
        return nativeController;
      },
    );
  }
}
