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
import '../services/default_engine_store.dart';
import '../services/download_manager.dart';
import '../services/exo_player.dart';
import '../l10n/app_localizations.dart';
import '../services/language_service.dart';
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
  DefaultEngine _defaultEngine = DefaultEngine.ask;
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
    _loadDefaultEngine();
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

  Future<void> _loadDefaultEngine() async {
    try {
      final engine = await DefaultEngineStore.load();
      if (mounted) setState(() => _defaultEngine = engine);
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
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppLocalizations.of(context).commonCancel))],
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
        title: Text(AppLocalizations.of(context).settingsSubtitleEncoding),
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
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel'))],
      ),
    );
    if (picked != null) {
      await SubtitlePrefs.saveEncoding(picked);
      if (mounted) setState(() => _subEncoding = picked);
    }
  }

  String _languageLabel(Locale? locale) {
    if (locale == null) return 'System default';
    final names = {'en': 'English', 'es': 'Spanish', 'zh': 'Chinese (Simplified)', 'ru': 'Russian'};
    return names[locale.languageCode] ?? locale.languageCode;
  }

  Future<void> _pickAppLanguage(BuildContext context) async {
    final current = LanguageService.instance.locale;
    final picked = await showDialog<Locale?>(
      context: context,
      builder: (ctx) {
        Locale? selected = current;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: Text(AppLocalizations.of(context).settingsLanguage),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: Text(AppLocalizations.of(context).settingsSystemDefault),
                    trailing: selected == null
                        ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                        : null,
                    onTap: () => Navigator.pop(ctx, null),
                  ),
                  for (final loc in AppLocalizations.supportedLocales)
                    ListTile(
                      title: Text(_languageLabel(loc)),
                      trailing: selected == loc
                          ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                          : null,
                      onTap: () => Navigator.pop(ctx, loc),
                    ),
                ],
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppLocalizations.of(context).commonCancel))],
          ),
        );
      },
    );
    if (picked != null || (picked == null && current != null)) {
      await LanguageService.instance.setLanguage(picked);
    }
  }

  Future<void> _loginOpensubtitles() async {
    final uCtrl = TextEditingController();
    final pCtrl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
        title: Text(AppLocalizations.of(context).settingsOpenSubtitlesSignIn),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: uCtrl, decoration: InputDecoration(labelText: 'Username')),
          TextField(controller: pCtrl, obscureText: true, decoration: InputDecoration(labelText: 'Password')),
          if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
          SizedBox(height: 8),
          Text(AppLocalizations.of(context).settingsOpensubAccountHint, style: TextStyle(color: Colors.white54, fontSize: 11)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel')),
          TextButton(onPressed: () async {
            try {
              await OpensubtitlesClient.instance.login(username: uCtrl.text.trim(), password: pCtrl.text);
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) { setDlg(() => err = e.toString()); }
          }, child: Text(AppLocalizations.of(context).settingsSignIn)),
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
    // Read only the user's SAVED key from prefs — NOT effectiveApiKey(),
    // which falls through to the compile-time TMDB_API_KEY define (injected
    // by --dart-define-from-file=.env). If we used effectiveApiKey here, the
    // build-time default would always show "Set (…)" and the Remove button
    // would appear to do nothing even though it clears prefs correctly.
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(TmdApi.prefsKey) ?? '';
    if (mounted) setState(() => _tmdbKey = saved);
  }

  Future<void> _editTmdbKey() async {
    final ctrl = TextEditingController(text: _tmdbKey.isEmpty ? '' : _tmdbKey);
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
        title: Text(AppLocalizations.of(context).settingsTmdbKey),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'Get a free key at themoviedb.org/settings/api',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          SizedBox(height: 12),
          TextField(
            controller: ctrl,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).settingsApiKeyHint,
              hintText: '32-character hex string',
            ),
          ),
          if (err != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(err!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel')),
          if (_tmdbKey.isNotEmpty)
            TextButton(onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove(TmdApi.prefsKey);
              if (ctx.mounted) Navigator.pop(ctx, true);
            }, child: Text(AppLocalizations.of(context).settingsRemove)),
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
          }, child: Text(AppLocalizations.of(context).commonSave)),
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
        title: Text(AppLocalizations.of(context).settingsClearCacheConfirm),
        content: Text(
          'Removes ${CacheCleaner.formatBytes(totalBytes)} of cached images '
          'and temporary files. Posters and details may need to be reloaded '
          'from the network the next time you open them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(AppLocalizations.of(context).commonClear),
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
    ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).settingsCacheCleared)));
    await _refreshDiskSize();
  }

  Future<void> _pickDownloadDir() async {
    final current = await DownloadManager.instance.getDownloadDir();
    final controller = TextEditingController(text: current);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).settingsDownloadFolder),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the full path for downloaded files.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                controller.text = '';
              },
              child: const Text('Reset to default'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppLocalizations.of(context).commonSave),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final path = controller.text.trim();
    await DownloadManager.instance.setDownloadDir(path);
    if (mounted) setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).settingsDownloadFolder)),
    );
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
                        SnackBar(
                          content: Text(AppLocalizations.of(context).settingsCouldNotOpenLink),
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
                'General',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ListenableBuilder(
              listenable: LanguageService.instance,
              builder: (context, _) => TvTile(
                leading: const Icon(Icons.language),
                title: Text(AppLocalizations.of(context).settingsLanguage),
                subtitle: Text(_languageLabel(LanguageService.instance.locale)),
                onTap: () => _pickAppLanguage(context),
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                AppLocalizations.of(context).settingsStorage,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.cleaning_services),
              title: Text(AppLocalizations.of(context).settingsClearCache),
              subtitle: Text(
                _cleared
                    ? AppLocalizations.of(context).settingsCacheClearedDesc
                    : '${CacheCleaner.formatBytes(_diskBytes)} on disk · '
                          '${CacheCleaner.formatBytes(CacheCleaner.memoryBytes())} in memory',
              ),
              onTap: _clearCache,
            ),
            TvTile(
              leading: const Icon(Icons.folder),
              title: Text(AppLocalizations.of(context).settingsDownloadFolder),
              subtitle: FutureBuilder<String>(
                future: DownloadManager.instance.getDownloadDir(),
                builder: (ctx, snap) {
                  final dir = snap.data ?? '';
                  final display = dir.replaceAll('/storage/emulated/0/', '/');
                  return Text(display.isEmpty ? 'Default' : display);
                },
              ),
              onTap: _pickDownloadDir,
            ),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  AppLocalizations.of(context).settingsAudio,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.surround_sound),
                title: Text(AppLocalizations.of(context).settingsAudioPassthrough),
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
                  AppLocalizations.of(context).settingsPlayer,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.swipe),
                title: Text(AppLocalizations.of(context).settingsSwipeGestures),
                subtitle: Text(
                  AppLocalizations.of(context).settingsSwipeDesc,
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
                  title: Text(AppLocalizations.of(context).settingsPip),
                  subtitle: Text(
                    AppLocalizations.of(context).settingsPipDesc,
                  ),
                  value: _pipEnabled,
                  onChanged: (value) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(kPipEnabledKey, value);
                    if (mounted) setState(() => _pipEnabled = value);
                  },
                ),
              if (defaultTargetPlatform == TargetPlatform.android)
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text(AppLocalizations.of(context).settingsDefaultEngine),
                  subtitle: Text(_defaultEngine.label),
                  onTap: () async {
                    final picked = await showDialog<DefaultEngine>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(AppLocalizations.of(context).settingsDefaultEngine),
                        content: RadioGroup<DefaultEngine>(
                          groupValue: _defaultEngine,
                          onChanged: (v) => Navigator.pop(ctx, v),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: DefaultEngine.values.map((e) {
                              final subtitle = switch (e) {
                                DefaultEngine.auto =>
                                  AppLocalizations.of(context).settingsEngineAutoDesc,
                                DefaultEngine.media3 =>
                                  AppLocalizations.of(context).settingsEngineMedia3Desc,
                                DefaultEngine.mpv =>
                                  AppLocalizations.of(context).settingsEngineMpvDesc,
                                DefaultEngine.ask =>
                                  AppLocalizations.of(context).settingsEngineAskDesc,
                              };
                              return RadioListTile<DefaultEngine>(
                                value: e,
                                title: Text(e.label),
                                subtitle: Text(subtitle,
                                    style: const TextStyle(fontSize: 12)),
                              );
                            }).toList(),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(AppLocalizations.of(context).commonCancel),
                          ),
                        ],
                      ),
                    );
                    if (picked != null && mounted) {
                      await DefaultEngineStore.save(picked);
                      setState(() => _defaultEngine = picked);
                    }
                  },
                ),
              SwitchListTile(
                secondary: const Icon(Icons.skip_next),
                title: Text(AppLocalizations.of(context).settingsAutoPlayNext),
                subtitle: Text(AppLocalizations.of(context).settingsAutoPlayNextDesc),
                value: _autoPlayNext,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kAutoPlayNextKey, value);
                  if (mounted) setState(() => _autoPlayNext = value);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.label),
                title: Text(AppLocalizations.of(context).settingsOnScreenBadges),
                subtitle: Text(
                  AppLocalizations.of(context).settingsBadgesDesc,
                ),
                value: _badgeEnabled,
                onChanged: (value) async {
                  await BadgePrefs.setEnabled(value);
                  if (mounted) setState(() => _badgeEnabled = value);
                },
              ),
              if (_badgeEnabled)
                ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  leading: const Icon(Icons.tune),
                  title: Text(AppLocalizations.of(context).settingsBadgeOptions),
                  subtitle: Text(AppLocalizations.of(context).settingsBadgeOptionsDesc),
                  children: [
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
                      subtitle: AppLocalizations.of(context).settingsBadgeVideoCodecDesc,
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
                        AppLocalizations.of(context).settingsBadgePlayback,
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
                      label: AppLocalizations.of(context).settingsBadgeTranscoding,
                      value: _badgeServerTranscode,
                      onChanged: (v) async {
                        await BadgePrefs.setServerTranscode(v);
                        if (mounted) setState(() => _badgeServerTranscode = v);
                      },
                    ),
                    _BadgeToggle(
                      icon: Icons.memory,
                      label: AppLocalizations.of(context).settingsBadgeDecoder,
                      subtitle: AppLocalizations.of(context).settingsBadgeDecoderDesc,
                      value: _badgeDecoder,
                      onChanged: (v) async {
                        await BadgePrefs.setDecoder(v);
                        if (mounted) setState(() => _badgeDecoder = v);
                      },
                    ),
                  ],
                ),
              // Subtitle appearance settings moved into the player's ⋮ sheet
              // (subtitle_settings_screen.dart is pushed from there now).
              // Volume Boost + Night Mode need Media3's LoudnessEnhancer
              // (Android only) — AVPlayer caps volume at 1.0 and exposes no
              // DRC, so showing these on iOS would be cosmetic no-ops.
              if (defaultTargetPlatform == TargetPlatform.android) ...[
                TvTile(
                  leading: const Icon(Icons.volume_up),
                  title: Text(AppLocalizations.of(context).settingsVolumeBoost),
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
                        title: Text(AppLocalizations.of(context).playerVolumeBoostTitle),
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
                            child: Text(AppLocalizations.of(context).commonCancel),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, temp),
                            child: Text(AppLocalizations.of(context).commonSave),
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
                  title: Text(AppLocalizations.of(context).settingsNightMode),
                  subtitle: Text(
                    AppLocalizations.of(context).settingsNightModeDesc,
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
                  title: Text(AppLocalizations.of(context).settingsVideoDecoder),
                  subtitle: Text(switch (_decoderMode) {
                    DecoderMode.hw => 'Hardware — fastest, HDR passthrough',
                    DecoderMode.sw => 'Software — compatibility fallback',
                    _ => 'Auto — hardware when available',
                  }),
                  onTap: () async {
                    final picked = await showDialog<DecoderMode>(
                      context: context,
                      builder: (context) => SimpleDialog(
                        title: Text(AppLocalizations.of(context).playerVideoDecoder),
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
                                        AppLocalizations.of(context).settingsDecoderHw,
                                      DecoderMode.sw =>
                                        AppLocalizations.of(context).settingsDecoderSw,
                                      _ =>
                                        AppLocalizations.of(context).settingsDecoderAuto,
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
                        SnackBar(
                          content: Text(AppLocalizations.of(context).settingsTakesEffectNextVideo),
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
              child: Text(AppLocalizations.of(context).settingsMetadata, style: TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            TvTile(
              leading: const Icon(Icons.movie),
              title: Text(AppLocalizations.of(context).settingsTmdbApiKey),
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
              child: Text(AppLocalizations.of(context).settingsSubtitles, style: TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.w600, fontSize: 12)),
            ),
            TvTile(
              leading: const Icon(Icons.subtitles),
              title: Text(AppLocalizations.of(context).settingsOpensubtitles),
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
              title: Text(AppLocalizations.of(context).settingsSubReadingLang),
              subtitle: Text(displayNameForNovaCode(_readingLang)),
              onTap: () => _pickLanguage(isReading: true),
            ),
            TvTile(
              leading: const Icon(Icons.download),
              title: Text(AppLocalizations.of(context).settingsSubDownloadLang),
              subtitle: Text(displayNameForNovaCode(_downloadLang)),
              onTap: () => _pickLanguage(isReading: false),
            ),
            TvTile(
              leading: const Icon(Icons.text_fields),
              title: Text(AppLocalizations.of(context).settingsSubEncoding),
              subtitle: Text(displayNameForCodepage(_subEncoding)),
              onTap: _pickEncoding,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome),
              title: Text(AppLocalizations.of(context).settingsAutoFetchSubs),
              subtitle: Text(AppLocalizations.of(context).settingsAutoDownloadSubs),
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
                  title: Text(AppLocalizations.of(context).settingsSimklSync),
                  subtitle: Text(
                    _simklLastSync == null
                        ? 'Push watched + resume to SIMKL'
                        : 'Last synced ${_formatWhen(_simklLastSync!)}',
                  ),
                  onTap: _syncSimkl,
                ),
                TvTile(
                  leading: const Icon(Icons.link_off),
                  title: Text(AppLocalizations.of(context).settingsSimklDisconnect),
                  subtitle: Text(AppLocalizations.of(context).settingsSimklSignOut),
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
                  title: Text(AppLocalizations.of(context).settingsSimklConnect),
                  subtitle: Text(AppLocalizations.of(context).settingsSimklSyncDesc),
                  onTap: _connectSimkl,
                ),
            ],
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                AppLocalizations.of(context).settingsAbout,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.memory),
              title: Text(AppLocalizations.of(context).settingsEngine),
              subtitle: Text(
                defaultTargetPlatform == TargetPlatform.iOS
                    ? 'AetherEngine (AVPlayer + FFmpeg)'
                    : 'ExoPlayer (Media3) + FFmpeg',
              ),
            ),
            TvTile(
              leading: const Icon(Icons.info_outline),
              title: Text(AppLocalizations.of(context).settingsVersion),
              subtitle: FutureBuilder<String>(
                future: _loadVersion(),
                builder: (context, snapshot) =>
                    Text(snapshot.hasData ? snapshot.data! : '…'),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.gavel),
              title: Text(AppLocalizations.of(context).settingsOpenLicenses),
              subtitle: Text(AppLocalizations.of(context).settingsGnuGpl),
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
                  SizedBox(height: 4),
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
      title: Text(AppLocalizations.of(context).settingsConnectSimkl),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppLocalizations.of(context).settingsSimklPairing),
            SizedBox(height: 12),
            Center(
              child: Text(
                widget.code.userCode,
                style: theme.textTheme.headlineMedium?.copyWith(
                  letterSpacing: 4,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            SizedBox(height: 12),
            Center(
              child: Text(
                widget.code.verificationUrl,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
            SizedBox(height: 16),
            Row(
              children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Expanded(child: Text(_status)),
              ],
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('Cancel'))],
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
