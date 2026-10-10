import 'dart:io' show Platform;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auto_play_store.dart';
import '../services/badge_prefs.dart';
import '../services/cache_cleaner.dart';
import '../services/decoder_mode.dart';
import '../services/default_engine_store.dart';
import '../services/download_manager.dart';
import '../services/entitlements.dart';
import '../services/exo_player.dart';
import '../services/image_cache_service.dart';
import '../l10n/app_localizations.dart';
import '../services/language_service.dart';
import '../services/opensubtitles_client.dart';
import '../services/subtitle_encodings.dart';
import '../services/subtitle_languages.dart';
import '../services/subtitle_prefs.dart';
import '../services/support_links.dart';
import '../services/mpv_downmix_store.dart';
import '../services/app_icon_service.dart';
import '../services/tone_map_store.dart';
import '../config/simkl_keys.dart';
import '../services/simkl_client.dart';
import '../services/tmdb_client.dart';
import '../services/the_tvdb_client.dart';
import '../services/watched_store.dart';
import '../utils/tv_helper.dart';
import '../widgets/tv_overscan.dart';
import '../services/accent_store.dart';
import '../services/layout_store.dart';
import '../services/font_store.dart';
import '../widgets/tv_tile.dart';
import 'licenses_screen.dart';
import 'credential_dialogs.dart';
import 'paywall_sheet.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _diskBytes = 0;
  int _imageCacheBytes = 0;
  bool _otherVideos = false;
  bool _cleared = false;
  bool _passthrough = false;
  bool _swipeGestures = true;
  bool _mpvNormalizeDownmix = false;
  bool _pipEnabled = true;
  bool _autoPlayNext = false;
  DecoderMode _decoderMode = DecoderMode.auto;
  DefaultEngine _defaultEngine = DefaultEngine.ask;
  ToneMapMode _toneMapMode = ToneMapMode.sdr;
  double _audioBoost = 1.0;
  bool _ffmpegAudio = false;
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
  bool _autoExpandFolders = true;
  int _scanDepth = 5;
  bool _badgeEnabled = true;
  bool _badgeHdr = true;
  bool _badgeAudio = true;
  bool _badgeResolution = false;
  bool _badgeVideoCodec = false;
  bool _badgeSpatialAudio = true;
  bool _badgeServerTranscode = true;
  bool _badgeDecoder = false;
  String _tmdbKey = '';
  String _theTvdbKey = '';
  String _theTvdbPin = '';
  bool _theTvdbFallback = true;
  MetadataProviderChoice _metadataProvider = MetadataProviderChoice.tmdb;
  String? _theTvdbStorageError;

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
    unawaited(_loadOtherVideos());
    _loadToneMapMode();
    _loadMpvDownmix();
    _loadAudioFilters();
    _loadSimkl();
    _loadOpensubtitles();
    _loadSubtitlePrefs();
    _loadBadgePrefs();
    _loadTmdbKey();
    _loadTheTvdb();
    _loadAutoExpandFolders();
  }

  Future<void> _loadOtherVideos() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool('dreamplayer.otherVideos') ?? false;
    if (!mounted) return;
    setState(() => _otherVideos = v);
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

  Future<void> _loadAutoExpandFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _autoExpandFolders = prefs.getBool('dreamplayer.autoExpandFolders') ?? true;
          _scanDepth = prefs.getInt('dreamplayer.scanDepth') ?? 5;
        });
      }
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

  Future<void> _loadMpvDownmix() async {
    try {
      final value = await MpvDownmixStore.load();
      if (mounted) setState(() => _mpvNormalizeDownmix = value);
    } catch (_) {}
  }

  Future<void> _loadToneMapMode() async {
    try {
      final mode = await ToneMapStore.load();
      if (mounted) setState(() => _toneMapMode = mode);
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
    final ok = await showOpensubtitlesSignInDialog(context);
    if (ok == true) await _loadOpensubtitles();
  }

  Future<void> _logoutOpensubtitles() async {
    await OpensubtitlesClient.instance.logout();
    if (mounted) setState(() { _osLoggedIn = false; _osUsername = null; _osRemaining = null; });
  }

  /// Returns true if a gated Settings feature is allowed, or shows the paywall.
  /// Mirrors `PlayerScreen._gate` — Android is always advanced, so this is a
  /// guaranteed no-op there (iOS-only monetization).
  Future<bool> _settingsGate() async {
    final gate = checkGate(
      gateEnabled: true,
      advanced: Entitlements.instance.isEntitled,
      paywallActive: Entitlements.instance.effectivePaywallEnabled,
    );
    if (gate != GateResult.paywallNeeded) return true;
    final purchased = await showPaywall(context);
    return purchased;
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
    final ok = await showTmdbApiKeyDialog(context, _tmdbKey);
    if (ok == true) await _loadTmdbKey();
  }

  Future<void> _loadTheTvdb() async {
    try {
      final store = TheTvdbClient.defaultCredentialStore;
      await store.load();
      final fallback = await TheTvdbClient.isFallbackEnabled();
      _metadataProvider = await TheTvdbClient.providerChoice();
      if (!mounted) return;
      setState(() {
        _theTvdbKey = store.apiKey ?? '';
        _theTvdbPin = store.pin ?? '';
        _theTvdbFallback = fallback;
        _theTvdbStorageError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _theTvdbKey = '';
        _theTvdbPin = '';
        _theTvdbFallback = false;
        _theTvdbStorageError = 'Secure storage unavailable';
      });
    }
  }

  Future<void> _editTheTvdbCredentials() async {
    final keyController = TextEditingController(text: _theTvdbKey);
    final pinController = TextEditingController(text: _theTvdbPin);
    var testing = false;
    String? testError;
    final changed = await showDialog<bool>(
      context: context,
      // `dialogContext` is the dialog's own context. It must be used for
      // anything looked up from inside the dialog — calling
      // `AppLocalizations.of(context)` with the SCREEN's context here builds a
      // widget in the dialog subtree that depends on an InheritedElement
      // outside it, which trips `assert(_dependents.isEmpty)` in
      // `InheritedElement.debugDeactivated` when the dialog is dismissed
      // (red screen on saving a TheTVDB key).
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('TheTVDB'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Optional TheTVDB v4 API key. Add a subscriber PIN only when your key requires one.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: keyController,
                  decoration: const InputDecoration(labelText: 'API key'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: pinController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Subscriber PIN (optional)'),
                ),
                if (testing) const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
                if (testError != null) Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    testError!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: testing
                  ? null
                  : () async {
                      setDialog(() {
                        testing = true;
                        testError = null;
                      });
                      final client = TheTvdbClient();
                      try {
                        await client.login(
                          apiKey: keyController.text.trim(),
                          pin: pinController.text.trim(),
                          persist: false,
                        );
                        if (ctx.mounted) {
                          setDialog(() {
                            testing = false;
                            testError = null;
                          });
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('TheTVDB connection succeeded.')),
                          );
                        }
                      } catch (error) {
                        if (ctx.mounted) {
                          setDialog(() {
                            testing = false;
                            testError = error.toString();
                          });
                        }
                      } finally {
                        client.dispose();
                      }
                    },
              child: const Text('Test connection'),
            ),
            TextButton(
              onPressed: testing
                  ? null
                  : () async {
                      try {
                        await TheTvdbClient.defaultCredentialStore.save(
                          apiKey: keyController.text,
                          pin: pinController.text,
                        );
                        TmdService.instance.refreshTheTvdbCredentials();
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (_) {
                        if (ctx.mounted) {
                          setDialog(() {
                            testError =
                                'Could not save TheTVDB credentials securely.';
                          });
                        }
                      }
                    },
              child: Text(AppLocalizations.of(dialogContext).commonSave),
            ),
          ],
        ),
      ),
    );
    // `showDialog`'s future completes when the route is POPPED — i.e. at the
    // START of the exit animation, not when it has finished. The dialog's
    // subtree (and its EditableText) therefore keeps rebuilding for a few more
    // frames. Disposing the controllers immediately made that rebuild hit
    // "A TextEditingController was used after being disposed", which corrupts
    // the element tree and makes the subsequent teardown assert
    // `_dependency.isEmpty` in InheritedElement.debugDeactivated — the red
    // screen this dialog used to show on saving a key.
    // Regression test: test/tvdb_dialog_save_test.dart
    await Future<void>.delayed(const Duration(milliseconds: 400));
    keyController.dispose();
    pinController.dispose();
    if (changed == true) await _loadTheTvdb();
  }

  /// Switching provider clears cached metadata, otherwise a title resolved
  /// earlier by the other provider keeps showing (and its own cache entry
  /// survives the change, so the choice would look like it did nothing).
  Future<void> _setMetadataProvider(MetadataProviderChoice choice) async {
    if (_metadataProvider == choice) return;
    await TheTvdbClient.setProviderChoice(choice);
    await TmdService.instance.clearAllResolved();
    if (!mounted) return;
    setState(() => _metadataProvider = choice);
  }

  Future<void> _setTheTvdbFallback(bool enabled) async {
    await TheTvdbClient.setFallbackEnabled(enabled);
    if (mounted) setState(() => _theTvdbFallback = enabled);
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
      final ffmpegAudio =
          (await SharedPreferences.getInstance()).getBool(kFfmpegAudioKey) ??
          false;
      if (mounted) {
        setState(() {
          _audioBoost = boost;
          _nightMode = night;
          _ffmpegAudio = ffmpegAudio;
        });
      }
    } catch (_) {}
  }

  String _cacheSizeLabel() {
    final parts = <String>[];
    if (_imageCacheBytes > 0) parts.add('${CacheCleaner.formatBytes(_imageCacheBytes)} images');
    if (_diskBytes > 0) parts.add('${CacheCleaner.formatBytes(_diskBytes)} temp');
    final memBytes = CacheCleaner.memoryBytes();
    if (memBytes > 0) parts.add('${CacheCleaner.formatBytes(memBytes)} memory');
    return parts.isEmpty ? 'Empty' : parts.join(' · ');
  }

  Future<void> _refreshDiskSize() async {
    final size = await CacheCleaner.diskSizeBytes();
    final imgSize = await ImageCacheService.instance.diskSizeBytes();
    if (mounted) {
      setState(() {
        _diskBytes = size;
        _imageCacheBytes = imgSize;
      });
    }
  }

  Future<void> _clearCache() async {
    final totalBytes = _diskBytes + _imageCacheBytes + CacheCleaner.memoryBytes();
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
    await ImageCacheService.instance.clear();
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
    if (!mounted) return;
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
    if (!mounted) return;
    setState(() {});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).settingsDownloadFolder)),
    );
  }

  /// Which engine-specific settings are worth showing.
  ///
  /// "Auto" and "Ask every time" can both land on either engine, so every
  /// engine option stays visible in those modes. They only disappear once the
  /// user has actually pinned one engine in Player -> Default playback engine,
  /// at which point the other engine's knobs are dead settings.
  bool get _flexibleEngine => _defaultEngine.allowFallback;
  bool get _showMpvSettings => _flexibleEngine || _defaultEngine == DefaultEngine.mpv;
  bool get _showMedia3Settings => _flexibleEngine || _defaultEngine == DefaultEngine.media3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTv = isTvMode(context);
    // Refresh cache size on every build so it stays live as images are cached.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDiskSize());

    return SafeArea(
      child: TvOverscan(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            // Premium section — shown when paywall is effective (iOS builds
            // with PAYWALL_ENABLED, or Android debug with simulate-free-user).
            if (Entitlements.instance.effectivePaywallEnabled) ...[
              ListenableBuilder(
                listenable: Entitlements.instance,
                builder: (context, _) {
                  final e = Entitlements.instance;
                  final entitled = e.isEntitled;
                  // Lifetime users: button vanishes entirely.
                  final showButton = !entitled || e.trialActive;
                  return ListTile(
                    leading: Icon(
                      Icons.workspace_premium,
                      color: entitled ? theme.colorScheme.primary : null,
                    ),
                    title: const Text('DreamPlayer Premium'),
                    subtitle: Text(
                      entitled
                          ? 'Thank you for supporting DreamPlayer'
                          : 'Unlock all premium features',
                    ),
                    trailing: showButton
                        ? TextButton(
                            onPressed: () => showPaywall(context),
                            style: TextButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text(
                              'Unlock',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600),
                            ),
                          )
                        : const Text(
                            'Active',
                            style: TextStyle(
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  );
                },
              ),
              const Divider(),
            ],
            // Support (donations) is Android-only: it unlocks nothing (fine
            // under Guideline 3.1.1) but the Razorpay/GitHub-Sponsors links
            // are out of place on iOS, where the paid tier is the IAP paywall.
            if (defaultTargetPlatform != TargetPlatform.iOS) ...[
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
            ],
            // === General ===
            ExpansionTile(
              leading: const Icon(Icons.settings),
              title: Text('General'),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
                ListenableBuilder(
                  listenable: LanguageService.instance,
                  builder: (context, _) => TvTile(
                    leading: const Icon(Icons.language),
                    title: Text(AppLocalizations.of(context).settingsLanguage),
                    subtitle: Text(_languageLabel(LanguageService.instance.locale)),
                    onTap: () => _pickAppLanguage(context),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.unfold_more),
                  title: const Text('Auto-expand folders'),
                  subtitle: const Text('Show each subfolder and video file as its own card on the home screen'),
                  value: _autoExpandFolders,
                  onChanged: (v) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('dreamplayer.autoExpandFolders', v);
                    if (mounted) setState(() => _autoExpandFolders = v);
                  },
                ),
                if (Platform.isAndroid)
                  SwitchListTile(
                    secondary: const Icon(Icons.video_library_outlined),
                    title: const Text('Other videos section'),
                    subtitle: const Text(
                        'List videos on this device that are not in your library, such as camera clips and music videos'),
                    value: _otherVideos,
                    onChanged: (v) async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('dreamplayer.otherVideos', v);
                      if (!mounted) return;
                      setState(() => _otherVideos = v);
                    },
                  ),
                if (_autoExpandFolders)
                  ListTile(
                    leading: const Icon(Icons.height),
                    title: const Text('Scan depth'),
                    subtitle: Text('$_scanDepth levels deep'),
                    trailing: DropdownButton<int>(
                      value: _scanDepth,
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1')),
                        DropdownMenuItem(value: 2, child: Text('2')),
                        DropdownMenuItem(value: 3, child: Text('3')),
                        DropdownMenuItem(value: 4, child: Text('4')),
                        DropdownMenuItem(value: 5, child: Text('5')),
                      ],
                      onChanged: (v) async {
                        if (v == null) return;
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setInt('dreamplayer.scanDepth', v);
                        if (mounted) setState(() => _scanDepth = v);
                      },
                    ),
                  ),
                SwitchListTile(
                  secondary: const Icon(Icons.offline_pin),
                  title: const Text('Offline image cache'),
                  subtitle: const Text('Save posters and backdrops for offline use'),
                  value: ImageCacheService.instance.enabled,
                  onChanged: (v) async {
                    await ImageCacheService.instance.setEnabled(v);
                    await _refreshDiskSize();
                    if (mounted) setState(() {});
                  },
                ),
                TvTile(
                  leading: const Icon(Icons.cleaning_services),
                  title: Text(AppLocalizations.of(context).settingsClearCache),
                  subtitle: Text(
                    _cleared
                        ? AppLocalizations.of(context).settingsCacheClearedDesc
                        : _cacheSizeLabel(),
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
                // Debug: simulate free user (debug builds only).
                if (kDebugMode) ...[
                  ListenableBuilder(
                    listenable: Entitlements.instance,
                    builder: (context, _) => SwitchListTile(
                      secondary: const Icon(Icons.bug_report, color: Colors.orange),
                      title: const Text('Debug: simulate free user', style: TextStyle(color: Colors.orange)),
                      subtitle: Text(
                        Entitlements.instance.debugFreeUser
                            ? 'ON — paywall + gates active on Android'
                            : 'OFF — Android = advanced (no paywall)',
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: Entitlements.instance.debugFreeUser,
                      onChanged: (v) => Entitlements.instance.setDebugFreeUser(v),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: Entitlements.instance,
                    builder: (context, _) {
                      final e = Entitlements.instance;
                      final sub = e.debugTrialExpired
                          ? 'ON — trial expired, gates fire (7-day trial bypassed)'
                          : e.trialActive
                              ? 'OFF — 7-day trial active, ${e.trialRemaining.inHours}h left'
                              : 'OFF — no active trial';
                      return SwitchListTile(
                        secondary: const Icon(Icons.event_busy, color: Colors.orange),
                        title: const Text('Debug: simulate trial expired', style: TextStyle(color: Colors.orange)),
                        subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
                        value: e.debugTrialExpired,
                        onChanged: (v) => Entitlements.instance.setDebugTrialExpired(v),
                      );
                    },
                  ),
                ],
              ],
            ),
            const _LayoutSection(),
            const Divider(),
            // === Player ===
            if (!isTv)
              ExpansionTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(AppLocalizations.of(context).settingsPlayer),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  // MPV only: this is an mpv engine property. Defaults off so
                  // the two Android engines play at the same level (issue #37).
                  if (defaultTargetPlatform == TargetPlatform.android)
                    SwitchListTile(
                      secondary: const Icon(Icons.surround_sound),
                      title: Text(AppLocalizations.of(context)
                          .settingsMpvNormalizeDownmix),
                      subtitle: Text(AppLocalizations.of(context)
                          .settingsMpvNormalizeDownmixDesc),
                      value: _mpvNormalizeDownmix,
                      onChanged: (value) async {
                        await MpvDownmixStore.save(value);
                        if (!mounted) return;
                        setState(() => _mpvNormalizeDownmix = value);
                        // Applied on the next MPV open; there is no handle on a
                        // player screen that is not currently pushed, and
                        // re-reading it per open is what _configureMpvAudio does
                        // anyway.
                      },
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
                              child: _ScrollableRadioList(
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
                  if (defaultTargetPlatform == TargetPlatform.android &&
                      _showMpvSettings)
                    ListTile(
                      leading: const Icon(Icons.palette_outlined),
                      title: Text(AppLocalizations.of(context).settingsToneMapMode),
                      subtitle: Text(_toneMapMode.label),
                      onTap: () async {
                        final picked = await showDialog<ToneMapMode>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(AppLocalizations.of(context).settingsToneMapMode),
                            content: RadioGroup<ToneMapMode>(
                              groupValue: _toneMapMode,
                              onChanged: (v) => Navigator.pop(ctx, v),
                              child: _ScrollableRadioList(
                                children: ToneMapMode.values.map((m) {
                                  final subtitle = switch (m) {
                                    ToneMapMode.sdr =>
                                      AppLocalizations.of(context).settingsToneMapSdrDesc,
                                    ToneMapMode.native =>
                                      AppLocalizations.of(context).settingsToneMapNativeDesc,
                                  };
                                  return RadioListTile<ToneMapMode>(
                                    value: m,
                                    title: Text(m.label),
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
                          await ToneMapStore.save(picked);
                          setState(() => _toneMapMode = picked);
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
                  if (defaultTargetPlatform == TargetPlatform.android &&
                      _showMedia3Settings)
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
                                      if (m != DecoderMode.ffmpegVideo)
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
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(40, 8, 16, 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Format',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
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
                            padding: const EdgeInsets.fromLTRB(40, 8, 16, 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                AppLocalizations.of(context).settingsBadgePlayback,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          if (defaultTargetPlatform == TargetPlatform.android &&
                              _showMedia3Settings)
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
                    ),
                  if (defaultTargetPlatform == TargetPlatform.android) ...[
                    // Issue #41. The libmpv engine decodes every track with
                    // libavcodec (`ad: ffmpeg`); Media3 normally prefers the
                    // platform MediaCodec decoders. Two different decoders means
                    // two different loudness for the same file, which is what
                    // made the engines sound mismatched. Turning this on routes
                    // Media3's audio through the same FFmpeg extension so there
                    // is one decoder for both.
                    //
                    // TV/HDMI passthrough still wins: the passthrough branch in
                    // PlayerCodecs.kt is checked before this one, so bitstream
                    // output is untouched when it is enabled.
                    if (_showMedia3Settings)
                      SwitchListTile(
                      secondary: const Icon(Icons.graphic_eq),
                      title: const Text('Match MPV audio (FFmpeg)'),
                      subtitle: const Text(
                        'Decode audio with the same FFmpeg as the MPV engine, '
                        'so both sound identical',
                      ),
                      value: _ffmpegAudio,
                      onChanged: (v) async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool(kFfmpegAudioKey, v);
                        if (mounted) setState(() => _ffmpegAudio = v);
                      },
                    ),
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
                ],
              ),
            // === Audio (Android only) ===
            if (defaultTargetPlatform == TargetPlatform.android)
              ExpansionTile(
                leading: const Icon(Icons.surround_sound),
                title: Text(AppLocalizations.of(context).settingsAudio),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
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
              ),
            // === Subtitles ===
            ExpansionTile(
              leading: const Icon(Icons.subtitles),
              title: Text(AppLocalizations.of(context).settingsSubtitles),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
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
                          : () async {
                              if (!await _settingsGate()) return;
                              if (!mounted) return;
                              await _loginOpensubtitles();
                            },
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
                  onTap: () async {
                    if (!await _settingsGate()) return;
                    if (!mounted) return;
                    _pickLanguage(isReading: false);
                  },
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
                    if (v && !await _settingsGate()) return;
                    if (!mounted) return;
                    await SubtitlePrefs.saveAutoFetch(v);
                    if (mounted) setState(() => _autoFetchSubs = v);
                  },
                ),
              ],
            ),
            // === Metadata ===
            ExpansionTile(
              leading: const Icon(Icons.movie),
              title: Text(AppLocalizations.of(context).settingsMetadata),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'TMDB is the primary provider and is what fetches the '
                    'details: title, overview, rating, genres, cast and season '
                    'and episode data. Enter your own key (free at '
                    'themoviedb.org → Settings → API → Create).\n\n'
                    'TheTVDB is an optional fallback that mainly widens the '
                    'pool of posters and backdrops you can pick from under '
                    '⋮ → Change poster / Change backdrop, and covers some '
                    'titles TMDB does not have.\n\n'
                    'You can use either one on its own, or both — TMDB gives '
                    'the richer detail, TheTVDB widens the artwork and covers '
                    'what TMDB lacks.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white54,
                      height: 1.35,
                    ),
                  ),
                ),
                 TvTile(
                   leading: const Icon(Icons.movie),
                   title: Text(AppLocalizations.of(context).settingsTmdbApiKey),
                   subtitle: Text(
                     _tmdbKey.isEmpty
                         ? 'Not set — required for details, season and episode data'
                         : 'Set (${_tmdbKey.substring(0, 4)}…${_tmdbKey.substring(_tmdbKey.length - 4)}) · fetches all details',
                   ),
                   onTap: _editTmdbKey,
                 ),
                 TvTile(
                   leading: const Icon(Icons.travel_explore),
                   title: const Text('TheTVDB metadata'),
                   subtitle: Text(
                     _theTvdbStorageError ??
                         (_theTvdbKey.isEmpty
                             ? 'Not configured — optional; extra posters and backdrops'
                             : 'Configured${_theTvdbPin.isEmpty ? '' : ' · PIN set'} · extra posters and backdrops'),
                   ),
                   onTap: _editTheTvdbCredentials,
                 ),
                 // Which provider resolves metadata (Settings toggle). This is
                 // a real choice, not the old fallback switch: picking TheTVDB
                 // makes it the PRIMARY resolver, so a user with only a
                 // TheTVDB key never queries TMDB at all.
                 Padding(
                   padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                   child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: [
                       const Text('Metadata provider'),
                       const SizedBox(height: 8),
                       SegmentedButton<MetadataProviderChoice>(
                         segments: const [
                           ButtonSegment(
                             value: MetadataProviderChoice.tmdb,
                             label: Text('TMDB'),
                             icon: Icon(Icons.movie, size: 18),
                           ),
                           ButtonSegment(
                             value: MetadataProviderChoice.theTvdb,
                             label: Text('TheTVDB'),
                             icon: Icon(Icons.travel_explore, size: 18),
                           ),
                         ],
                         selected: {_metadataProvider},
                         onSelectionChanged: (selection) =>
                             _setMetadataProvider(selection.first),
                       ),
                       const SizedBox(height: 6),
                       Text(
                         _metadataProvider == MetadataProviderChoice.tmdb
                             ? 'TMDB resolves everything. TheTVDB is used only '
                                 'as a fallback, if you enable it below.'
                             : 'TheTVDB resolves everything. TMDB is not queried.',
                         style: Theme.of(context).textTheme.bodySmall?.copyWith(
                               color: Colors.white54,
                             ),
                       ),
                     ],
                   ),
                 ),
                 SwitchListTile(
                   secondary: const Icon(Icons.merge_type),
                   title: const Text('Use TheTVDB as fallback'),
                   subtitle: const Text(
                     'Only used when TMDB is the selected provider',
                   ),
                   value: _metadataProvider == MetadataProviderChoice.tmdb &&
                       _theTvdbFallback &&
                       _theTvdbKey.isNotEmpty,
                   onChanged: (_metadataProvider != MetadataProviderChoice.tmdb ||
                           _theTvdbKey.isEmpty)
                       ? null
                       : (value) => _setTheTvdbFallback(value),
                 ),
               ],

            ),
            // === SIMKL ===
            if (simklClientId.isNotEmpty)
              ExpansionTile(
                leading: const Icon(Icons.sync),
                title: const Text('SIMKL'),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
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
              ),
            // === About ===
            ExpansionTile(
              leading: const Icon(Icons.info_outline),
              title: Text(AppLocalizations.of(context).settingsAbout),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
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
                TvTile(
                  leading: const Icon(Icons.description),
                  title: const Text('Terms of Use'),
                  subtitle: const Text('End User License Agreement'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => launchUrl(
                    Uri.parse('https://mangeshghodke.github.io/DreamPlayer/terms.html'),
                  ),
                ),
                TvTile(
                  leading: const Icon(Icons.privacy_tip),
                  title: const Text('Privacy Policy'),
                  subtitle: const Text('How your data is handled'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => launchUrl(
                    Uri.parse('https://mangeshghodke.github.io/DreamPlayer/privacy.html'),
                  ),
                ),
              ],
            ),
            // === FAQ ===
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
                      'details screen, tap "Fix match", and search for the '
                      'right title yourself. That search covers every '
                      'metadata provider you have configured, so it will find '
                      'the title even if it is not on TMDB.',
            ),
            _FaqTile(
              icon: Icons.travel_explore,
              question: 'Do I need TMDB, or can I use TheTVDB only?',
              answer: 'Either one works on its own — you can use TMDB only, '
                  'TheTVDB only, or both.\n\n'
                  'TMDB stays the primary provider because it covers movies '
                  'and series most completely. TheTVDB is optional and kicks '
                  'in when TMDB has no confident match for a file, which is '
                  'common for some anime and older or more obscure series. '
                  'If you only add a TheTVDB key and leave TMDB unset, it '
                  'simply becomes your provider and everything still works.\n\n'
                  'To set one up, go to Settings → Metadata. Get a free TMDB '
                  'key at themoviedb.org → Settings → API → Create, and a '
                  'TheTVDB v4 key at thetvdb.com/api. TheTVDB also asks for a '
                  'Subscriber PIN on some accounts — leave it blank if yours '
                  'does not need one.\n\n'
                  'Keys are stored in the platform secure store (Android '
                  'Keystore / iOS Keychain), never in plain text.\n\n'
                  'You do not need to pick a provider anywhere else: "Get '
                  'info" and "Fix match" search everything you have '
                  'configured and show one combined result list, so a title '
                  'that is only on TheTVDB will still turn up.',
            ),
            // Restore Purchases — always visible when paywall is effective.
            // Opens the paywall sheet so the user can see which product is
            // active and explicitly tap Restore there.
            if (Entitlements.instance.effectivePaywallEnabled) ...[
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('Restore Purchases'),
                subtitle: const Text('Open paywall to restore or view your subscription'),
                onTap: () => showPaywall(context),
              ),
              const Divider(),
            ],
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
      return 'unknown';
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

/// Library layout preferences (issue #34, item 6): how dense the home grids
/// are, and how many cards per row.
class _LayoutSection extends StatelessWidget {
  const _LayoutSection();

  static String _modeLabel(LibraryViewMode m) => switch (m) {
        LibraryViewMode.poster => 'Poster',
        LibraryViewMode.compact => 'Compact',
        LibraryViewMode.list => 'List',
      };

  static String _columnsLabel(int columns) =>
      columns <= 0 ? 'Automatic' : '$columns per row';

  static String _thumbSizeLabel(EpisodeThumbSize s) => switch (s) {
        EpisodeThumbSize.small => 'Small',
        EpisodeThumbSize.medium => 'Medium',
        EpisodeThumbSize.large => 'Large',
      };

  /// Episode-row thumbnail size (issue #38, item 3). Rows pick this up live,
  /// so no screen needs rebuilding and there is nothing to "apply".
  Future<void> _pickThumbSize(BuildContext context) async {
    final store = LayoutStore.instance;
    final choice = await showDialog<EpisodeThumbSize>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Episode thumbnails'),
        children: [
          for (final s in EpisodeThumbSize.values)
            ListTile(
              title: Text(_thumbSizeLabel(s)),
              subtitle: Text(switch (s) {
                EpisodeThumbSize.small => 'Current size — densest list',
                EpisodeThumbSize.medium => 'Bigger artwork, still compact',
                EpisodeThumbSize.large =>
                  'Best on tablets — automatically reduced on narrow phones',
              }),
              trailing:
                  s == store.thumbSize ? const Icon(Icons.check, size: 20) : null,
              onTap: () => Navigator.of(ctx).pop(s),
            ),
        ],
      ),
    );
    // The section is already wrapped in a ListenableBuilder on LayoutStore, so
    // the subtitle label updates itself.
    if (choice != null) await store.setThumbSize(choice);
  }

  Future<void> _pickMode(BuildContext context) async {
    final store = LayoutStore.instance;
    final choice = await showDialog<LibraryViewMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Library view'),
        children: [
          for (final m in LibraryViewMode.values)
            ListTile(
              title: Text(_modeLabel(m)),
              subtitle: Text(switch (m) {
                LibraryViewMode.poster =>
                  'Full poster cards with title and subtitle',
                LibraryViewMode.compact =>
                  'Smaller artwork and a shorter text block — fit more titles',
                LibraryViewMode.list =>
                  'One wide row per title with artwork on the left',
              }),
              trailing: m == store.mode
                  ? const Icon(Icons.check, size: 20)
                  : null,
              onTap: () => Navigator.of(ctx).pop(m),
            ),
        ],
      ),
    );
    if (choice != null) await store.setMode(choice);
  }

  Future<void> _pickColumns(BuildContext context) async {
    final store = LayoutStore.instance;
    // Automatic plus every count the grids will honour (capped per width).
    final options = <int>[0, 2, 3, 4, 5, 6];
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Items per row'),
        children: [
          for (final n in options)
            ListTile(
              title: Text(n <= 0 ? 'Automatic' : '$n'),
              subtitle: n <= 0
                  ? const Text('Fit to the screen width')
                  : const Text('Capped on narrow screens so cards stay readable'),
              trailing: n == store.columns
                  ? const Icon(Icons.check, size: 20)
                  : null,
              onTap: () => Navigator.of(ctx).pop(n),
            ),
        ],
      ),
    );
    if (choice != null) await store.setColumns(choice);
  }

  /// Searchable list of the whole Google Fonts catalog (~1900 families).
  /// Each preview is rendered in its own font, so the choice is visual.
  Future<void> _pickFont(BuildContext context) async {
    final all = FontStore.catalog;
    final choice = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _FontPickerSheet(allFamilies: all),
    );
    if (choice == null) return;
    await FontStore.setFamily(choice.isEmpty ? null : choice);
    AppSettingsBus.instance.notify();
  }

  Future<void> _pickAccent(BuildContext context) async {
    final choice = await showDialog<Accent>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Accent colour'),
        children: [
          for (final a in AccentStore.accents)
            ListTile(
              title: Text(a.label),
              trailing: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: a.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24),
                ),
              ),
              onTap: () => Navigator.of(ctx).pop(a),
            ),
        ],
      ),
    );
    if (choice != null) await AccentStore.instance.setAccent(choice);
  }

  /// Icon picker (issue #23). Uses a bottom sheet rather than a dialog: the
  /// list is five entries with previews, which is comfortable in a sheet and
  /// avoids another height-constrained Column.
  Future<void> _pickAppIcon(BuildContext context) async {
    final svc = AppIconService.instance;
    final picked = await showModalBottomSheet<AppIconStyle>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final style in AppIconStyle.values)
                TvTile(
                  leading: SizedBox(
                    width: 34,
                    height: 34,
                    child: Image.asset(
                      switch (style) {
                        AppIconStyle.defaultIcon => 'assets/app_icon_dark.png',
                        AppIconStyle.markOnly => 'assets/app_icon_mark.png',
                        AppIconStyle.red => 'assets/app_icon_mark_red.png',
                        AppIconStyle.green => 'assets/app_icon_mark_green.png',
                        AppIconStyle.cyan => 'assets/app_icon_mark_cyan.png',
                      },
                      width: 34,
                      height: 34,
                      fit: BoxFit.contain,
                    ),
                  ),
                  title: Text(style.label),
                  subtitle: Text(style.description),
                  trailing: svc.style == style
                      ? const Icon(Icons.check, size: 20)
                      : null,
                  onTap: () => Navigator.pop(sheetCtx, style),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == svc.style) return;
    final ok = await svc.apply(picked);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Icon updated to ${picked.label}. Your launcher may take a moment to refresh it.'
              : 'Could not change the icon on this device.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.palette_outlined),
      title: const Text('Appearance'),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        ListenableBuilder(
          listenable: Listenable.merge([
            LayoutStore.instance,
            AccentStore.instance,
          ]),
          builder: (context, _) {
            final store = LayoutStore.instance;
            return Column(
              children: [
                TvTile(
                  leading: const Icon(Icons.density_medium),
                  title: const Text('Library view'),
                  subtitle: Text(_modeLabel(store.mode)),
                  onTap: () => _pickMode(context),
                ),
                TvTile(
                  leading: const Icon(Icons.photo_size_select_large),
                  title: const Text('Episode thumbnails'),
                  subtitle: Text(
                    _thumbSizeLabel(LayoutStore.instance.thumbSize),
                  ),
                  onTap: () => _pickThumbSize(context),
                ),
                TvTile(
                  leading: const Icon(Icons.grid_on),
                  title: const Text('Items per row'),
                  subtitle: Text(_columnsLabel(store.columns)),
                  onTap: () => _pickColumns(context),
                ),
                // Self-contained: the value comes from the store, and the bus
                // rebuilds both this tile and the app theme when it changes.
                ValueListenableBuilder(
                  valueListenable: AppSettingsBus.instance,
                  builder: (context, _, _) => ListTile(
                    leading: const Icon(Icons.font_download),
                    title: const Text('Font'),
                    subtitle: Text(
                      FontStore.family ?? 'Platform default',
                    ),
                    trailing: FontStore.family == null
                        ? null
                        : const Icon(Icons.check, size: 20),
                    onTap: () => _pickFont(context),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Accent colour'),
                  subtitle: const Text('Applies to buttons, highlights and the player UI'),
                  trailing: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: AccentStore.instance.accent.color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24),
                    ),
                  ),
                  onTap: () => _pickAccent(context),
                ),
                // Launcher icon (issue #23). Android-only in practice: the
                // toggle needs an activity-alias, and TV has no launcher.
                if (defaultTargetPlatform != TargetPlatform.iOS &&
                    !isTvMode(context))
                  ListenableBuilder(
                    listenable: AppIconService.instance,
                    builder: (context, _) {
                      final style = AppIconService.instance.style;
                      return TvTile(
                        leading: const Icon(Icons.apps),
                        title: const Text('App icon'),
                        subtitle: Text(style.description),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _pickAppIcon(context),
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Searchable Google Fonts picker.
///
/// The catalog is large (~1900), so the list is lazy and filtered by a search
/// field. "Platform default" clears the choice. Each row previews its own
/// family, which is the whole point of the feature.
class _FontPickerSheet extends StatefulWidget {
  const _FontPickerSheet({required this.allFamilies});

  final List<String> allFamilies;

  @override
  State<_FontPickerSheet> createState() => _FontPickerSheetState();
}

class _FontPickerSheetState extends State<_FontPickerSheet> {
  String _query = '';

  /// The family rendered in its own typeface, falling back to the app font if
  /// the family is unknown or fails to load. Never throws: an unknown family
  /// would take the whole picker down mid-scroll.
  TextStyle _previewStyle(String name) {
    final base = Theme.of(context).textTheme.titleMedium ??
        const TextStyle(fontSize: 16);
    try {
      return GoogleFonts.getFont(
        name,
        fontSize: base.fontSize,
        fontWeight: FontWeight.w500,
        color: base.color,
      );
    } catch (_) {
      return base;
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final matches = q.isEmpty
        ? widget.allFamilies
        : widget.allFamilies.where((f) => f.toLowerCase().contains(q)).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search fonts',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Platform default'),
            trailing: FontStore.family == null
                ? const Icon(Icons.check, size: 20)
                : null,
            onTap: () => Navigator.of(context).pop(''),
          ),
          const Divider(height: 1),
          Expanded(
            child: matches.isEmpty
                ? const Center(child: Text('No font matches that name'))
                : ListView.builder(
                    controller: scrollController,
                    itemCount: matches.length,
                    itemBuilder: (context, i) {
                      final name = matches[i];
                      // Must go through google_fonts: it registers the real
                      // family (e.g. "Poppins_regular") and kicks off the
                      // load. A raw TextStyle(fontFamily: name) asks the
                      // engine for a family literally called "Poppins",
                      // which is never registered — so every row silently
                      // rendered in the default font and the list looked
                      // uniform. The subtitle stays in the app font so the
                      // family name is still readable while it downloads.
                      return ListTile(
                        title: Text(
                          name,
                          style: _previewStyle(name),
                        ),
                        subtitle: Text(
                          name,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        trailing: FontStore.family == name
                            ? const Icon(Icons.check, size: 20)
                            : null,
                        onTap: () => Navigator.of(context).pop(name),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Scrollable body for an option dialog's radio list.
///
/// A plain `Column(mainAxisSize: MainAxisSize.min)` is unbounded inside an
/// `AlertDialog`. Four `RadioListTile`s that each carry a title *and* a
/// description are around 410 px, but a landscape phone only gives the dialog
/// roughly 230 px -- so it overflowed the bottom (148 px on a 2400x1080
/// viewport, and still 28 px in portrait, which is why this was easy to miss).
///
/// The height cap also stops the dialog stretching edge-to-edge on a tablet,
/// while leaving short lists completely untouched.
///
/// Note this only applies to `AlertDialog`. The decoder chooser uses
/// `SimpleDialog`, which already scrolls its own children.
class _ScrollableRadioList extends StatelessWidget {
  const _ScrollableRadioList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Plain scroll view, deliberately WITHOUT a ConstrainedBox height cap.
    // Capping the child instead makes the Column overflow its own constraint
    // (a Column that wants 292 px inside a 180 px box still overflows) rather
    // than growing and scrolling. The scroll view is already bounded by the
    // AlertDialog's Flexible, so it just needs room to be taller than the
    // viewport and scroll within it.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}
