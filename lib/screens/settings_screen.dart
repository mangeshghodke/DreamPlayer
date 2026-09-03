import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auto_play_store.dart';
import '../services/badge_prefs.dart';
import '../services/cache_cleaner.dart';
import '../services/decoder_mode.dart';
import '../services/exo_player.dart';
import '../services/opensubtitles_client.dart';
import '../services/subtitle_encodings.dart';
import '../services/subtitle_languages.dart';
import '../services/subtitle_prefs.dart';
import '../services/support_links.dart';
import '../config/simkl_keys.dart';
import '../services/simkl_client.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../utils/tv_helper.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_tile.dart';
import 'licenses_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _diskBytes = 0;
  bool _cleared = false;
  bool _passthrough = false;
  bool _swipeGestures = true;
  bool _pipEnabled = true;
  bool _autoPlayNext = false;
  DecoderMode _decoderMode = DecoderMode.auto;
  double _audioBoost = 1.0;
  bool _nightMode = false;
  bool _simklConnected = false;
  DateTime? _simklLastSync;
  String? _osUsername;
  int? _osRemaining;
  bool _osLoggedIn = false;
  String _readingLang = 'system';
  String _downloadLang = 'eng';
  int _subEncoding = 0;
  bool _autoFetchSubs = false;
  bool _badgeEnabled = true;
  bool _badgeHdr = true;
  bool _badgeAudio = true;
  bool _badgeResolution = false;
  bool _badgeVideoCodec = false;
  bool _badgeSpatialAudio = true;
  bool _badgeServerTranscode = true;
  bool _badgeDecoder = false;
  String _tmdbKey = '';

  @override
  void initState() {
    super.initState();
    _refreshDiskSize();
    _loadPassthrough();
    _loadSwipeGestures();
    _loadPipEnabled();
    _loadAutoPlayNext();
    _loadDecoderMode();
    _loadAudioFilters();
    _loadSimkl();
    _loadOpensubtitles();
    _loadSubtitlePrefs();
    _loadBadgePrefs();
    _loadTmdbKey();
  }

  Future<void> _loadSimkl() async {
    final client = SimklClient();
    if (!client.isConfigured) return;
    try {
      final connected = await client.isAuthenticated();
      final lastSync = await client.lastSyncAt();
      if (mounted) {
        setState(() {
          _simklConnected = connected;
          _simklLastSync = lastSync;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadOpensubtitles() async {
    final c = OpensubtitlesClient.instance;
    if (!c.hasApiKey) return;
    try {
      await c.fetchUserInfo().then((info) {
        final data = info['data'] as Map<String, dynamic>?;
        final remaining = data?['remaining_downloads'] as int?;
        if (mounted) setState(() { _osLoggedIn = true; _osUsername = c.username; _osRemaining = remaining; });
      }).catchError((_) {
        if (mounted) setState(() { _osLoggedIn = false; _osUsername = null; });
      });
      if (!c.isLoggedIn && mounted) {
        setState(() { _osLoggedIn = false; _osUsername = c.username; });
      }
    } catch (_) {
      if (mounted) setState(() { _osLoggedIn = c.isLoggedIn; _osUsername = c.username; });
    }
  }

  Future<void> _loadSubtitlePrefs() async {
    try {
      final reading = await SubtitlePrefs.loadReadingLanguage();
      final download = await SubtitlePrefs.loadDownloadLanguage();
      final enc = await SubtitlePrefs.loadEncoding();
      final auto = await SubtitlePrefs.loadAutoFetch();
      if (mounted) setState(() { _readingLang = reading; _downloadLang = download; _subEncoding = enc; _autoFetchSubs = auto; });
    } catch (_) {}
  }

  Future<void> _loadBadgePrefs() async {
    try {
      final f = await BadgePrefs.load();
      if (mounted) {
        setState(() {
          _badgeEnabled = f.enabled;
          _badgeHdr = f.hdr;
          _badgeAudio = f.audio;
          _badgeResolution = f.resolution;
          _badgeVideoCodec = f.videoCodec;
          _badgeSpatialAudio = f.spatialAudio;
          _badgeServerTranscode = f.serverTranscode;
          _badgeDecoder = f.decoder;
        });
      }
    } catch (_) {}
  }

  Future<void> _pickLanguage({required bool isReading}) async {
    final current = isReading ? _readingLang : _downloadLang;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isReading ? 'Subtitle reading language' : 'Download language'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: RadioGroup<String>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: ListView.builder(
              itemCount: subtitleLanguages.length,
              itemBuilder: (_, i) {
                final l = subtitleLanguages[i];
                return RadioListTile<String>(
                  value: l.novaCode,
                  title: Text(l.displayName),
                );
              },
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    );
    if (picked != null) {
      if (isReading) {
        await SubtitlePrefs.saveReadingLanguage(picked);
        if (mounted) setState(() => _readingLang = picked);
      } else {
        await SubtitlePrefs.saveDownloadLanguage(picked);
        if (mounted) setState(() => _downloadLang = picked);
      }
    }
  }

  Future<void> _pickEncoding() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Subtitle encoding'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: RadioGroup<int>(
            groupValue: _subEncoding,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: ListView.builder(
              itemCount: subtitleEncodings.length,
              itemBuilder: (_, i) {
                final e = subtitleEncodings[i];
                return RadioListTile<int>(
                  value: e.codepage,
                  title: Text(e.displayName),
                );
              },
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    );
    if (picked != null) {
      await SubtitlePrefs.saveEncoding(picked);
      if (mounted) setState(() => _subEncoding = picked);
    }
  }

  Future<void> _loginOpensubtitles() async {
    final uCtrl = TextEditingController();
    final pCtrl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
        title: const Text('OpenSubtitles sign in'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: uCtrl, decoration: const InputDecoration(labelText: 'Username')),
          TextField(controller: pCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
          if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
          const SizedBox(height: 8),
          const Text('Free account = 20/day (anonymous = 5/day). Create at opensubtitles.com', style: TextStyle(color: Colors.white54, fontSize: 11)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () async {
            try {
              await OpensubtitlesClient.instance.login(username: uCtrl.text.trim(), password: pCtrl.text);
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) { setDlg(() => err = e.toString()); }
          }, child: const Text('Sign in')),
        ],
      )),
    );
    if (ok == true) await _loadOpensubtitles();
  }

  Future<void> _logoutOpensubtitles() async {
    await OpensubtitlesClient.instance.logout();
    if (mounted) setState(() { _osLoggedIn = false; _osUsername = null; _osRemaining = null; });
  }

  Future<void> _loadTmdbKey() async {
    final key = await TmdApi().effectiveApiKey();
    if (mounted) setState(() => _tmdbKey = key);
  }

  Future<void> _editTmdbKey() async {
    final ctrl = TextEditingController(text: _tmdbKey.isEmpty ? '' : _tmdbKey);
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
        title: const Text('TMDB API key'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Get a free key at themoviedb.org/settings/api',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            decoration: const InputDecoration(
              labelText: 'API key (v3 auth)',
              hintText: '32-character hex string',
            ),
          ),
          if (err != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(err!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          if (_tmdbKey.isNotEmpty)
            TextButton(onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove(TmdApi.prefsKey);
              if (ctx.mounted) Navigator.pop(ctx, true);
            }, child: const Text('Remove')),
          TextButton(onPressed: () async {
            final entered = ctrl.text.trim();
            if (entered.isNotEmpty && entered.length != 32) {
              setDlg(() => err = 'Key must be 32 characters');
              return;
            }
            final prefs = await SharedPreferences.getInstance();
            if (entered.isEmpty) {
              await prefs.remove(TmdApi.prefsKey);
            } else {
              await prefs.setString(TmdApi.prefsKey, entered);
            }
            if (ctx.mounted) Navigator.pop(ctx, true);
          }, child: const Text('Save')),
        ],
      )),
    );
    if (ok == true) await _loadTmdbKey();
  }

  Future<void> _loadPassthrough() async {
    final enabled = await isAudioPassthroughEnabled();
    if (mounted) setState(() => _passthrough = enabled);
  }

  Future<void> _loadSwipeGestures() async {
    try {
      final enabled = await areSwipeGesturesEnabled();
      if (mounted) setState(() => _swipeGestures = enabled);
    } catch (_) {}
  }

  Future<void> _loadPipEnabled() async {
    try {
      final enabled = await isPipEnabled();
      if (mounted) setState(() => _pipEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _loadAutoPlayNext() async {
    try {
      final enabled = await isAutoPlayNextEnabled();
      if (mounted) setState(() => _autoPlayNext = enabled);
    } catch (_) {}
  }

  Future<void> _loadDecoderMode() async {
    try {
      final mode = await DecoderModeStore.load();
      if (mounted) setState(() => _decoderMode = mode);
    } catch (_) {}
  }

  Future<void> _loadAudioFilters() async {
    try {
      final boost = await PlaybackBoostStore.load();
      final night = await NightModeStore.load();
      if (mounted) {
        setState(() {
          _audioBoost = boost;
          _nightMode = night;
        });
      }
    } catch (_) {}
  }

  Future<void> _refreshDiskSize() async {
    final size = await CacheCleaner.diskSizeBytes();
    if (mounted) setState(() => _diskBytes = size);
  }

  Future<void> _clearCache() async {
    final totalBytes = _diskBytes + CacheCleaner.memoryBytes();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear cache?'),
        content: Text(
          'Removes ${CacheCleaner.formatBytes(totalBytes)} of cached images '
          'and temporary files. Posters and details may need to be reloaded '
          'from the network the next time you open them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await CacheCleaner.clearDisk();
    CacheCleaner.clearMemoryImages();
    if (!mounted) return;
    setState(() => _cleared = true);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Cache cleared')));
    await _refreshDiskSize();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTv = isTvMode(context);

    return SafeArea(
      child: TvOverscan(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Support',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final option in supportOptions)
              TvTile(
                leading: Icon(option.icon),
                title: Text(option.title),
                subtitle: Text(option.subtitle),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () async {
                  try {
                    await openSupportUrl(option.url);
                  } on PlatformException {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Could not open this link'),
                        ),
                      );
                    }
                  }
                },
              ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Storage',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.cleaning_services),
              title: const Text('Clear cache'),
              subtitle: Text(
                _cleared
                    ? 'Cached images and temporary files cleared'
                    : '${CacheCleaner.formatBytes(_diskBytes)} on disk · '
                          '${CacheCleaner.formatBytes(CacheCleaner.memoryBytes())} in memory',
              ),
              onTap: _clearCache,
            ),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Audio',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.surround_sound),
                title: const Text('Audio passthrough'),
                subtitle: Text(
                  _passthrough
                      ? 'Auto — passthrough when HDMI detected'
                      : 'Off — decode to PCM (default)',
                ),
                value: _passthrough,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kAudioPassthroughKey, value);
                  if (mounted) setState(() => _passthrough = value);
                },
              ),
            ],
            if (!isTv) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Player',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.swipe),
                title: const Text('Swipe gestures'),
                subtitle: const Text(
                  'Swipe left side for brightness, right side for volume',
                ),
                value: _swipeGestures,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kSwipeGesturesKey, value);
                  if (mounted) setState(() => _swipeGestures = value);
                },
              ),
              // PiP on both platforms: Android auto-enters from
              // onUserLeaveHint (native pref read), iOS arms
              // canStartPictureInPictureAutomaticallyFromInline from the same
              // pref. Pointless on TV, so it hides with the other
              // phone-only controls.
              if (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS)
                SwitchListTile(
                  secondary: const Icon(Icons.picture_in_picture),
                  title: const Text('Picture-in-picture'),
                  subtitle: const Text(
                    'Keep playing in a floating window when you leave the app',
                  ),
                  value: _pipEnabled,
                  onChanged: (value) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(kPipEnabledKey, value);
                    if (mounted) setState(() => _pipEnabled = value);
                  },
                ),
              SwitchListTile(
                secondary: const Icon(Icons.skip_next),
                title: const Text('Auto-play next episode'),
                subtitle: const Text('Play the next episode when one ends'),
                value: _autoPlayNext,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kAutoPlayNextKey, value);
                  if (mounted) setState(() => _autoPlayNext = value);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.label),
                title: const Text('On-screen badges'),
                subtitle: const Text(
                  'Show format chips on screen while playing',
                ),
                value: _badgeEnabled,
                onChanged: (value) async {
                  await BadgePrefs.setEnabled(value);
                  if (mounted) setState(() => _badgeEnabled = value);
                },
              ),
              if (_badgeEnabled) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(56, 8, 16, 4),
                  child: Text(
                    'Format',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _BadgeToggle(
                  icon: Icons.high_quality,
                  label: 'HDR',
                  subtitle: 'DV / HDR10 / HDR10+ / HLG / SDR',
                  value: _badgeHdr,
                  onChanged: (v) async {
                    await BadgePrefs.setHdr(v);
                    if (mounted) setState(() => _badgeHdr = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.audiotrack,
                  label: 'Audio codec',
                  subtitle: 'E-AC3 · 5.1 / DTS-HD · 7.1 / AAC …',
                  value: _badgeAudio,
                  onChanged: (v) async {
                    await BadgePrefs.setAudio(v);
                    if (mounted) setState(() => _badgeAudio = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.videocam,
                  label: 'Video codec',
                  subtitle: 'HEVC / H.264 / AV1',
                  value: _badgeVideoCodec,
                  onChanged: (v) async {
                    await BadgePrefs.setVideoCodec(v);
                    if (mounted) setState(() => _badgeVideoCodec = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.aspect_ratio,
                  label: 'Resolution',
                  value: _badgeResolution,
                  onChanged: (v) async {
                    await BadgePrefs.setResolution(v);
                    if (mounted) setState(() => _badgeResolution = v);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(56, 8, 16, 4),
                  child: Text(
                    'Playback',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (defaultTargetPlatform == TargetPlatform.android)
                _BadgeToggle(
                  icon: Icons.spatial_audio,
                  label: 'Spatial audio',
                  value: _badgeSpatialAudio,
                  onChanged: (v) async {
                    await BadgePrefs.setSpatialAudio(v);
                    if (mounted) setState(() => _badgeSpatialAudio = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.sync,
                  label: 'Server transcoding',
                  value: _badgeServerTranscode,
                  onChanged: (v) async {
                    await BadgePrefs.setServerTranscode(v);
                    if (mounted) setState(() => _badgeServerTranscode = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.memory,
                  label: 'Decoder',
                  subtitle: 'HW / SW / auto',
                  value: _badgeDecoder,
                  onChanged: (v) async {
                    await BadgePrefs.setDecoder(v);
                    if (mounted) setState(() => _badgeDecoder = v);
                  },
                ),
              ],
              // Subtitle appearance settings moved into the player's ⋮ sheet
              // (subtitle_settings_screen.dart is pushed from there now).
              // Volume Boost + Night Mode need Media3's LoudnessEnhancer
              // (Android only) — AVPlayer caps volume at 1.0 and exposes no
              // DRC, so showing these on iOS would be cosmetic no-ops.
              if (defaultTargetPlatform == TargetPlatform.android) ...[
                TvTile(
                  leading: const Icon(Icons.volume_up),
                  title: const Text('Volume Boost'),
                  subtitle: Text(
                    _audioBoost > 1.01
                        ? '${_audioBoost.toStringAsFixed(1)}× (LoudnessEnhancer)'
                        : 'Off — 1.0×',
                  ),
                  onTap: () async {
                    double temp = _audioBoost;
                    final picked = await showDialog<double>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Volume Boost'),
                        content: StatefulBuilder(
                          builder: (context, setD) => Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Slider(
                                value: temp.clamp(1.0, 3.0),
                                min: 1.0,
                                max: 3.0,
                                divisions: 20,
                                label: '${temp.toStringAsFixed(1)}×',
                                onChanged: (v) => setD(
                                  () =>
                                      temp = double.parse(v.toStringAsFixed(1)),
                                ),
                              ),
                              Text(
                                '${temp.toStringAsFixed(1)}×',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, temp),
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                    );
                    if (picked != null) {
                      await PlaybackBoostStore.save(picked);
                      if (mounted) setState(() => _audioBoost = picked);
                    }
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.nights_stay),
                  title: const Text('Night Mode'),
                  subtitle: const Text(
                    'Compress dynamic range for quiet listening',
                  ),
                  value: _nightMode,
                  onChanged: (value) async {
                    await NightModeStore.save(value);
                    if (mounted) setState(() => _nightMode = value);
                  },
                ),
              ],
              if (defaultTargetPlatform == TargetPlatform.android)
                TvTile(
                  leading: const Icon(Icons.memory),
                  title: const Text('Video decoder'),
                  subtitle: Text(switch (_decoderMode) {
                    DecoderMode.hw => 'Hardware — fastest, HDR passthrough',
                    DecoderMode.sw => 'Software — compatibility fallback',
                    _ => 'Auto — hardware when available',
                  }),
                  onTap: () async {
                    final picked = await showDialog<DecoderMode>(
                      context: context,
                      builder: (context) => SimpleDialog(
                        title: const Text('Video decoder'),
                        children: [
                          RadioGroup<DecoderMode>(
                            groupValue: _decoderMode,
                            onChanged: (v) => Navigator.of(context).pop(v),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final m in DecoderMode.values)
                                  RadioListTile<DecoderMode>(
                                    value: m,
                                    title: Text(m.label),
                                    subtitle: Text(switch (m) {
                                      DecoderMode.hw =>
                                        'Force hardware decoders',
                                      DecoderMode.sw =>
                                        'Prefer software decoders',
                                      _ =>
                                        'Let the system choose (recommended)',
                                    }),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                    if (picked != null) {
                      await DecoderModeStore.save(picked);
                      if (mounted) setState(() => _decoderMode = picked);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Takes effect on next video'),
                        ),
                      );
                    }
                  },
                ),
            ],
            // Subtitles — OpenSubtitles (Nova-style): anonymous 5/day, free login 20/day
            const Divider(),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Metadata', style: TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            TvTile(
              leading: const Icon(Icons.movie),
              title: const Text('TMDB API key'),
              subtitle: Text(
                _tmdbKey.isEmpty
                    ? 'Not set — enter your own key'
                    : 'Set (${_tmdbKey.substring(0, 4)}…${_tmdbKey.substring(_tmdbKey.length - 4)})',
              ),
              onTap: _editTmdbKey,
            ),
            const Divider(),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Subtitles', style: TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            TvTile(
              leading: const Icon(Icons.subtitles),
              title: const Text('OpenSubtitles'),
              subtitle: Text(
                !OpensubtitlesClient.instance.hasApiKey
                    ? 'Add OPENSUBTITLES_API_KEY in .env and rebuild'
                    : _osLoggedIn
                        ? 'Signed in as ${_osUsername ?? ''}${_osRemaining != null ? ' · $_osRemaining remaining' : ''}'
                        : 'Anonymous — 5/day, sign in for 20/day',
              ),
              onTap: !OpensubtitlesClient.instance.hasApiKey
                  ? null
                  : _osLoggedIn
                      ? _logoutOpensubtitles
                      : _loginOpensubtitles,
            ),
            TvTile(
              leading: const Icon(Icons.closed_caption),
              title: const Text('Subtitle reading language'),
              subtitle: Text(displayNameForNovaCode(_readingLang)),
              onTap: () => _pickLanguage(isReading: true),
            ),
            TvTile(
              leading: const Icon(Icons.download),
              title: const Text('Subtitle download language'),
              subtitle: Text(displayNameForNovaCode(_downloadLang)),
              onTap: () => _pickLanguage(isReading: false),
            ),
            TvTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('Subtitle encoding'),
              subtitle: Text(displayNameForCodepage(_subEncoding)),
              onTap: _pickEncoding,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome),
              title: const Text('Auto-fetch subtitles'),
              subtitle: const Text('Download best match when no subtitles found'),
              value: _autoFetchSubs,
              onChanged: (v) async {
                await SubtitlePrefs.saveAutoFetch(v);
                if (mounted) setState(() => _autoFetchSubs = v);
              },
            ),
            if (simklClientId.isNotEmpty) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'SIMKL',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_simklConnected) ...[
                TvTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Sync now'),
                  subtitle: Text(
                    _simklLastSync == null
                        ? 'Push watched + resume to SIMKL'
                        : 'Last synced ${_formatWhen(_simklLastSync!)}',
                  ),
                  onTap: _syncSimkl,
                ),
                TvTile(
                  leading: const Icon(Icons.link_off),
                  title: const Text('Disconnect SIMKL'),
                  subtitle: const Text('Sign out and stop syncing'),
                  onTap: () async {
                    await SimklClient().signOut();
                    if (mounted) {
                      setState(() {
                        _simklConnected = false;
                        _simklLastSync = null;
                      });
                    }
                  },
                ),
              ] else
                TvTile(
                  leading: const Icon(Icons.link),
                  title: const Text('Connect SIMKL'),
                  subtitle: const Text('Sync watched history with simkl.com (free unlimited)'),
                  onTap: _connectSimkl,
                ),
            ],
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'About',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.memory),
              title: const Text('Engine'),
              subtitle: Text(
                defaultTargetPlatform == TargetPlatform.iOS
                    ? 'AetherEngine (AVPlayer + FFmpeg)'
                    : 'ExoPlayer (Media3) + FFmpeg',
              ),
            ),
            TvTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Version'),
              subtitle: FutureBuilder<String>(
                future: _loadVersion(),
                builder: (context, snapshot) =>
                    Text(snapshot.hasData ? snapshot.data! : '…'),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.gavel),
              title: const Text('Open-source licenses'),
              subtitle: const Text('GNU GPL v3.0 and third-party notices'),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const LicensesScreen(),
                  ),
                );
              },
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'FAQ',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (defaultTargetPlatform == TargetPlatform.android)
              _FaqTile(
                icon: Icons.play_circle_outline,
                question: 'Which playback engine should I use?',
                answer: 'DreamPlayer offers two engines on Android:\n\n'
                    '• Media3 (default) — hardware-accelerated, supports '
                    'Dolby Vision, HDR10, HDR10+, and all audio codecs via '
                    'FFmpeg. Best for most users.\n\n'
                    '• libmpv — software fallback using FFmpeg. Slower but '
                    'handles some edge-case formats Media3 cannot decode. '
                    'Does not support Dolby Vision or HDR passthrough.\n\n'
                    'Use Media3 unless a specific file fails to play, in '
                    'which case try libmpv from the error screen.',
              ),
            _FaqTile(
              icon: Icons.refresh,
              question: 'How do I refresh network share listings?',
              answer: 'Pull down on any folder listing in SMB, WebDAV, FTP, '
                  'DLNA, or Jellyfin to refresh. This is useful when you '
                  'add, rename, or delete files on your NAS or PC and want '
                  'to see the changes without navigating back to the server list.',
            ),
            _FaqTile(
              icon: Icons.movie_filter,
              question: 'How should I name my files for TMDB metadata?',
              answer: 'DreamPlayer tries to match filenames against The Movie '
                      'Database (TMDB) to fetch posters, titles, ratings, and '
                      'other metadata.\n\n'
                      'Best results come from clean names:\n'
                      '  Dune (2021)\n'
                      '  The Matrix 1999\n'
                      '  Breaking Bad S01E01\n\n'
                      'These are automatically cleaned up (quality tags like '
                      '1080p, WEB-DL, and release group tags like -RARBG are '
                      'stripped before searching).\n\n'
                      'You can also manually fix a match: open the file\'s '
                      'details screen, tap "Fix match", and search TMDB '
                      'yourself.',
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                children: [
                  Text(
                    'Made with ❤️ by Mangesh Ghodke',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'DreamPlayer',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } on Exception {
      return '0.0.7';
    }
  }

  String _formatWhen(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _connectSimkl() async {
    final client = SimklClient();
    try {
      final code = await client.requestPinCode();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _SimklConnectDialog(client: client, code: code),
      );
      await _loadSimkl();
    } on SimklException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _syncSimkl() async {
    final client = SimklClient();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final items = await _collectSimklItems();
      await client.markWatched(items);
      if (mounted) {
        setState(() => _simklLastSync = DateTime.now());
        messenger.showSnackBar(SnackBar(content: Text('Synced ${items.length} item(s) to SIMKL')));
      }
    } on SimklException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<List<SimklWatchItem>> _collectSimklItems() async {
    final keys = await WatchedStore.load();
    final items = <SimklWatchItem>[];
    for (final key in keys) {
      final meta = TmdService.instance.metaFor(key);
      if (meta == null) continue;
      final movie = meta.movie;
      if (movie.id == 0) continue;
      final parsed = ParsedFileName.parse(key);
      items.add(
        SimklWatchItem(
          tmdbId: movie.id,
          isTv: movie.kind == TmdKind.tv,
          season: parsed.isEpisode ? parsed.season : null,
          episode: parsed.isEpisode ? parsed.episode : null,
        ),
      );
    }
    return items;
  }
}

/// Device-flow dialog: shows the user code + activation URL and polls in the
class _SimklConnectDialog extends StatefulWidget {
  const _SimklConnectDialog({required this.client, required this.code});
  final SimklClient client;
  final SimklPinCode code;
  @override
  State<_SimklConnectDialog> createState() => _SimklConnectDialogState();
}

class _SimklConnectDialogState extends State<_SimklConnectDialog> {
  String _status = 'Waiting for authorization…';
  @override
  void initState() {
    super.initState();
    _poll();
  }

  Future<void> _poll() async {
    try {
      final ok = await widget.client.pollForToken(widget.code);
      if (!mounted) return;
      setState(() => _status = ok ? 'Connected!' : 'Timed out — try again.');
      if (ok) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (mounted) Navigator.of(context).pop();
      }
    } on SimklException catch (e) {
      if (!mounted) return;
      setState(() => _status = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Connect SIMKL'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Go to the address below and enter this code:'),
            const SizedBox(height: 12),
            Center(
              child: Text(
                widget.code.userCode,
                style: theme.textTheme.headlineMedium?.copyWith(
                  letterSpacing: 4,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                widget.code.verificationUrl,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(child: Text(_status)),
              ],
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

/// Compact badge toggle row — icon + label + optional subtitle + switch.
/// Much lighter than a full CheckboxListTile: 40px height, no checkbox.
class _BadgeToggle extends StatelessWidget {
  const _BadgeToggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        title: Text(label, style: const TextStyle(fontSize: 14)),
        subtitle: subtitle != null
            ? Text(subtitle!, style: const TextStyle(fontSize: 11))
            : null,
        trailing: Switch.adaptive(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        onTap: () => onChanged(!value),
      ),
    );
  }
}

/// Expandable FAQ tile — icon + question header, expands to show answer text.
class _FaqTile extends StatelessWidget {
  const _FaqTile({
    required this.icon,
    required this.question,
    required this.answer,
  });

  final IconData icon;
  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
      title: Text(question, style: const TextStyle(fontSize: 14)),
      childrenPadding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
      children: [
        Text(
          answer,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}
