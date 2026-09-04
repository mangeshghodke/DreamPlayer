import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../l10n/context_text.dart';
import '../services/app_preferences.dart';
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

  Future<void> _pickAppLanguage() async {
    final strings = AppLocalizations.of(context);
    final controller = AppPreferencesController.instance;
    final picked = await showDialog<AppLanguage>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(strings.selectLanguage),
        children: [
          RadioGroup<AppLanguage>(
            groupValue: controller.language,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<AppLanguage>(
                  value: AppLanguage.system,
                  title: Text(strings.languageSystem),
                ),
                RadioListTile<AppLanguage>(
                  value: AppLanguage.simplifiedChinese,
                  title: Text(strings.languageChinese),
                ),
                RadioListTile<AppLanguage>(
                  value: AppLanguage.english,
                  title: Text(strings.languageEnglish),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) await controller.setLanguage(picked);
  }

  Future<void> _pickThemeMode() async {
    final strings = AppLocalizations.of(context);
    final controller = AppPreferencesController.instance;
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(strings.selectTheme),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: controller.themeMode,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in ThemeMode.values)
                  RadioListTile<ThemeMode>(
                    value: mode,
                    title: Text(switch (mode) {
                      ThemeMode.system => strings.themeSystem,
                      ThemeMode.light => strings.themeLight,
                      ThemeMode.dark => strings.themeDark,
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) await controller.setThemeMode(picked);
  }

  String _languageLabel(AppLocalizations strings) =>
      switch (AppPreferencesController.instance.language) {
        AppLanguage.system => strings.languageSystem,
        AppLanguage.english => strings.languageEnglish,
        AppLanguage.simplifiedChinese => strings.languageChinese,
      };

  String _themeLabel(AppLocalizations strings) =>
      switch (AppPreferencesController.instance.themeMode) {
        ThemeMode.system => strings.themeSystem,
        ThemeMode.light => strings.themeLight,
        ThemeMode.dark => strings.themeDark,
      };

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
      await c
          .fetchUserInfo()
          .then((info) {
            final data = info['data'] as Map<String, dynamic>?;
            final remaining = data?['remaining_downloads'] as int?;
            if (mounted)
              setState(() {
                _osLoggedIn = true;
                _osUsername = c.username;
                _osRemaining = remaining;
              });
          })
          .catchError((_) {
            if (mounted)
              setState(() {
                _osLoggedIn = false;
                _osUsername = null;
              });
          });
      if (!c.isLoggedIn && mounted) {
        setState(() {
          _osLoggedIn = false;
          _osUsername = c.username;
        });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _osLoggedIn = c.isLoggedIn;
          _osUsername = c.username;
        });
    }
  }

  Future<void> _loadSubtitlePrefs() async {
    try {
      final reading = await SubtitlePrefs.loadReadingLanguage();
      final download = await SubtitlePrefs.loadDownloadLanguage();
      final enc = await SubtitlePrefs.loadEncoding();
      final auto = await SubtitlePrefs.loadAutoFetch();
      if (mounted)
        setState(() {
          _readingLang = reading;
          _downloadLang = download;
          _subEncoding = enc;
          _autoFetchSubs = auto;
        });
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
        title: Text(
          isReading
              ? context.tr('Subtitle reading language', '字幕阅读语言')
              : context.tr('Download language', '下载语言'),
        ),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('Cancel', '取消')),
          ),
        ],
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
        title: Text(context.tr('Subtitle encoding', '字幕编码')),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('Cancel', '取消')),
          ),
        ],
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
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(context.tr('OpenSubtitles sign in', '登录 OpenSubtitles')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: uCtrl,
                decoration: InputDecoration(
                  labelText: context.tr('Username', '用户名'),
                ),
              ),
              TextField(
                controller: pCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.tr('Password', '密码'),
                ),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    err!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                context.tr(
                  'Free account = 20/day (anonymous = 5/day). Create at opensubtitles.com',
                  '免费账户每天 20 次（匿名用户每天 5 次），可在 opensubtitles.com 注册。',
                ),
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.tr('Cancel', '取消')),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await OpensubtitlesClient.instance.login(
                    username: uCtrl.text.trim(),
                    password: pCtrl.text,
                  );
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  setDlg(() => err = e.toString());
                }
              },
              child: Text(context.tr('Sign in', '登录')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await _loadOpensubtitles();
  }

  Future<void> _logoutOpensubtitles() async {
    await OpensubtitlesClient.instance.logout();
    if (mounted)
      setState(() {
        _osLoggedIn = false;
        _osUsername = null;
        _osRemaining = null;
      });
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
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(context.tr('TMDB API key', 'TMDB API 密钥')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(
                  'Get a free key at themoviedb.org/settings/api',
                  '可在 themoviedb.org/settings/api 免费获取密钥',
                ),
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                decoration: InputDecoration(
                  labelText: context.tr('API key (v3 auth)', 'API 密钥（v3 认证）'),
                  hintText: context.tr(
                    '32-character hex string',
                    '32 位十六进制字符串',
                  ),
                ),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    err!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.tr('Cancel', '取消')),
            ),
            if (_tmdbKey.isNotEmpty)
              TextButton(
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.remove(TmdApi.prefsKey);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                },
                child: Text(context.tr('Remove', '移除')),
              ),
            TextButton(
              onPressed: () async {
                final entered = ctrl.text.trim();
                if (entered.isNotEmpty && entered.length != 32) {
                  setDlg(
                    () => err = context.tr(
                      'Key must be 32 characters',
                      '密钥必须是 32 个字符',
                    ),
                  );
                  return;
                }
                final prefs = await SharedPreferences.getInstance();
                if (entered.isEmpty) {
                  await prefs.remove(TmdApi.prefsKey);
                } else {
                  await prefs.setString(TmdApi.prefsKey, entered);
                }
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: Text(context.tr('Save', '保存')),
            ),
          ],
        ),
      ),
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
        title: Text(context.tr('Clear cache?', '清理缓存？')),
        content: Text(
          context.tr(
            'Removes ${CacheCleaner.formatBytes(totalBytes)} of cached images and temporary files. Posters and details may need to be reloaded from the network the next time you open them.',
            '将删除 ${CacheCleaner.formatBytes(totalBytes)} 的缓存图片和临时文件。下次打开时，海报和详情可能需要重新从网络加载。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.tr('Cancel', '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.tr('Clear', '清理')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await CacheCleaner.clearDisk();
    CacheCleaner.clearMemoryImages();
    if (!mounted) return;
    setState(() => _cleared = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('Cache cleared', '缓存已清理'))),
    );
    await _refreshDiskSize();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTv = isTvMode(context);
    final strings = AppLocalizations.of(context);

    return SafeArea(
      child: TvOverscan(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                strings.appearance,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.language),
              title: Text(strings.language),
              subtitle: Text(_languageLabel(strings)),
              onTap: _pickAppLanguage,
            ),
            TvTile(
              leading: const Icon(Icons.brightness_6_outlined),
              title: Text(strings.theme),
              subtitle: Text(_themeLabel(strings)),
              onTap: _pickThemeMode,
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                strings.support,
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
                          content: Text(
                            context.tr('Could not open this link', '无法打开此链接'),
                          ),
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
                strings.storage,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.cleaning_services),
              title: Text(strings.clearCache),
              subtitle: Text(
                _cleared
                    ? context.tr(
                        'Cached images and temporary files cleared',
                        '缓存图片和临时文件已清理',
                      )
                    : context.tr(
                        '${CacheCleaner.formatBytes(_diskBytes)} on disk · ${CacheCleaner.formatBytes(CacheCleaner.memoryBytes())} in memory',
                        '磁盘 ${CacheCleaner.formatBytes(_diskBytes)} · 内存 ${CacheCleaner.formatBytes(CacheCleaner.memoryBytes())}',
                      ),
              ),
              onTap: _clearCache,
            ),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  context.tr('Audio', '音频'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.surround_sound),
                title: Text(strings.audioPassthrough),
                subtitle: Text(
                  _passthrough
                      ? context.tr(
                          'Auto — passthrough when HDMI detected',
                          '自动——检测到 HDMI 时启用直通',
                        )
                      : context.tr(
                          'Off — decode to PCM (default)',
                          '关闭——解码为 PCM（默认）',
                        ),
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
                  strings.player,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.swipe),
                title: Text(strings.swipeGestures),
                subtitle: Text(
                  context.tr(
                    'Swipe left side for brightness, right side for volume',
                    '在左侧滑动调节亮度，在右侧滑动调节音量',
                  ),
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
                  title: Text(strings.pictureInPicture),
                  subtitle: Text(
                    context.tr(
                      'Keep playing in a floating window when you leave the app',
                      '离开应用后继续在悬浮窗口中播放',
                    ),
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
                title: Text(strings.autoPlayNextEpisode),
                subtitle: Text(
                  context.tr(
                    'Play the next episode when one ends',
                    '当前一集结束后播放下一集',
                  ),
                ),
                value: _autoPlayNext,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kAutoPlayNextKey, value);
                  if (mounted) setState(() => _autoPlayNext = value);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.label),
                title: Text(strings.onScreenBadges),
                subtitle: Text(
                  context.tr(
                    'Show format chips on screen while playing',
                    '播放时在屏幕上显示格式标记',
                  ),
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
                  title: Text(strings.badgeOptions),
                  subtitle: Text(
                    context.tr('Choose which chips to show', '选择要显示的标记'),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(56, 8, 16, 4),
                      child: Text(
                        context.tr('Format', '格式'),
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
                      label: context.tr('Audio codec', '音频编码'),
                      subtitle: 'E-AC3 · 5.1 / DTS-HD · 7.1 / AAC …',
                      value: _badgeAudio,
                      onChanged: (v) async {
                        await BadgePrefs.setAudio(v);
                        if (mounted) setState(() => _badgeAudio = v);
                      },
                    ),
                    _BadgeToggle(
                      icon: Icons.videocam,
                      label: context.tr('Video codec', '视频编码'),
                      subtitle: 'HEVC / H.264 / AV1',
                      value: _badgeVideoCodec,
                      onChanged: (v) async {
                        await BadgePrefs.setVideoCodec(v);
                        if (mounted) setState(() => _badgeVideoCodec = v);
                      },
                    ),
                    _BadgeToggle(
                      icon: Icons.aspect_ratio,
                      label: context.tr('Resolution', '分辨率'),
                      value: _badgeResolution,
                      onChanged: (v) async {
                        await BadgePrefs.setResolution(v);
                        if (mounted) setState(() => _badgeResolution = v);
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(56, 8, 16, 4),
                      child: Text(
                        context.tr('Playback', '播放'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (defaultTargetPlatform == TargetPlatform.android)
                      _BadgeToggle(
                        icon: Icons.spatial_audio,
                        label: context.tr('Spatial audio', '空间音频'),
                        value: _badgeSpatialAudio,
                        onChanged: (v) async {
                          await BadgePrefs.setSpatialAudio(v);
                          if (mounted) setState(() => _badgeSpatialAudio = v);
                        },
                      ),
                    _BadgeToggle(
                      icon: Icons.sync,
                      label: context.tr('Server transcoding', '服务器转码'),
                      value: _badgeServerTranscode,
                      onChanged: (v) async {
                        await BadgePrefs.setServerTranscode(v);
                        if (mounted) setState(() => _badgeServerTranscode = v);
                      },
                    ),
                    _BadgeToggle(
                      icon: Icons.memory,
                      label: context.tr('Decoder', '解码器'),
                      subtitle: 'HW / SW / auto',
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
                  title: Text(strings.volumeBoost),
                  subtitle: Text(
                    _audioBoost > 1.01
                        ? '${_audioBoost.toStringAsFixed(1)}× (LoudnessEnhancer)'
                        : context.tr('Off — 1.0×', '关闭——1.0×'),
                  ),
                  onTap: () async {
                    double temp = _audioBoost;
                    final picked = await showDialog<double>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(context.tr('Volume Boost', '音量增强')),
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
                            child: Text(context.tr('Cancel', '取消')),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, temp),
                            child: Text(context.tr('Save', '保存')),
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
                  title: Text(strings.nightMode),
                  subtitle: Text(
                    context.tr(
                      'Compress dynamic range for quiet listening',
                      '压缩动态范围，适合安静环境收听',
                    ),
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
                  title: Text(strings.videoDecoder),
                  subtitle: Text(switch (_decoderMode) {
                    DecoderMode.hw => context.tr(
                      'Hardware — fastest, HDR passthrough',
                      '硬件——速度最快，支持 HDR 直通',
                    ),
                    DecoderMode.sw => context.tr(
                      'Software — compatibility fallback',
                      '软件——兼容性后备方案',
                    ),
                    _ => context.tr(
                      'Auto — hardware when available',
                      '自动——可用时使用硬件',
                    ),
                  }),
                  onTap: () async {
                    final picked = await showDialog<DecoderMode>(
                      context: context,
                      builder: (context) => SimpleDialog(
                        title: Text(context.tr('Video decoder', '视频解码器')),
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
                                    title: Text(switch (m) {
                                      DecoderMode.hw => context.tr(
                                        'Hardware',
                                        '硬件',
                                      ),
                                      DecoderMode.sw => context.tr(
                                        'Software',
                                        '软件',
                                      ),
                                      _ => context.tr('Auto', '自动'),
                                    }),
                                    subtitle: Text(switch (m) {
                                      DecoderMode.hw => context.tr(
                                        'Force hardware decoders',
                                        '强制使用硬件解码器',
                                      ),
                                      DecoderMode.sw => context.tr(
                                        'Prefer software decoders',
                                        '优先使用软件解码器',
                                      ),
                                      _ => context.tr(
                                        'Let the system choose (recommended)',
                                        '由系统选择（推荐）',
                                      ),
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
                          content: Text(
                            context.tr(
                              'Takes effect on next video',
                              '将在下一个视频生效',
                            ),
                          ),
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
              child: Text(
                strings.metadata,
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.movie),
              title: Text(strings.tmdbApiKey),
              subtitle: Text(
                _tmdbKey.isEmpty
                    ? context.tr(
                        'Not set — enter your own key',
                        '未设置——请输入自己的密钥',
                      )
                    : '${context.tr('Set', '已设置')} (${_tmdbKey.substring(0, 4)}…${_tmdbKey.substring(_tmdbKey.length - 4)})',
              ),
              onTap: _editTmdbKey,
            ),
            const Divider(),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                strings.subtitles,
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.subtitles),
              title: const Text('OpenSubtitles'),
              subtitle: Text(
                !OpensubtitlesClient.instance.hasApiKey
                    ? context.tr(
                        'OpenSubtitles is not configured',
                        '尚未配置 OpenSubtitles',
                      )
                    : _osLoggedIn
                    ? '${context.tr('Signed in as', '已登录为')} ${_osUsername ?? ''}${_osRemaining != null ? ' · $_osRemaining ${context.tr('remaining', '次剩余')}' : ''}'
                    : context.tr(
                        'Anonymous — 5/day, sign in for 20/day',
                        '匿名用户——每天 5 次，登录后每天 20 次',
                      ),
              ),
              onTap: !OpensubtitlesClient.instance.hasApiKey
                  ? null
                  : _osLoggedIn
                  ? _logoutOpensubtitles
                  : _loginOpensubtitles,
            ),
            TvTile(
              leading: const Icon(Icons.closed_caption),
              title: Text(strings.subtitleReadingLanguage),
              subtitle: Text(displayNameForNovaCode(_readingLang)),
              onTap: () => _pickLanguage(isReading: true),
            ),
            TvTile(
              leading: const Icon(Icons.download),
              title: Text(strings.subtitleDownloadLanguage),
              subtitle: Text(displayNameForNovaCode(_downloadLang)),
              onTap: () => _pickLanguage(isReading: false),
            ),
            TvTile(
              leading: const Icon(Icons.text_fields),
              title: Text(strings.subtitleEncoding),
              subtitle: Text(displayNameForCodepage(_subEncoding)),
              onTap: _pickEncoding,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome),
              title: Text(strings.autoFetchSubtitles),
              subtitle: Text(
                context.tr(
                  'Download best match when no subtitles found',
                  '未找到字幕时自动下载最佳匹配项',
                ),
              ),
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
                  title: Text(context.tr('Sync now', '立即同步')),
                  subtitle: Text(
                    _simklLastSync == null
                        ? context.tr(
                            'Push watched + resume to SIMKL',
                            '将观看记录和续播进度同步到 SIMKL',
                          )
                        : '${context.tr('Last synced', '上次同步')} ${_formatWhen(_simklLastSync!)}',
                  ),
                  onTap: _syncSimkl,
                ),
                TvTile(
                  leading: const Icon(Icons.link_off),
                  title: Text(context.tr('Disconnect SIMKL', '断开 SIMKL')),
                  subtitle: Text(
                    context.tr('Sign out and stop syncing', '退出登录并停止同步'),
                  ),
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
                  title: Text(context.tr('Connect SIMKL', '连接 SIMKL')),
                  subtitle: Text(
                    context.tr(
                      'Sync watched history with simkl.com (free unlimited)',
                      '与 simkl.com 同步观看记录（免费且不限量）',
                    ),
                  ),
                  onTap: _connectSimkl,
                ),
            ],
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                strings.about,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.memory),
              title: Text(strings.engine),
              subtitle: Text(
                defaultTargetPlatform == TargetPlatform.iOS
                    ? 'AetherEngine (AVPlayer + FFmpeg)'
                    : 'ExoPlayer (Media3) + FFmpeg',
              ),
            ),
            TvTile(
              leading: const Icon(Icons.info_outline),
              title: Text(strings.version),
              subtitle: FutureBuilder<String>(
                future: _loadVersion(),
                builder: (context, snapshot) =>
                    Text(snapshot.hasData ? snapshot.data! : '…'),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.gavel),
              title: Text(strings.openSourceLicenses),
              subtitle: Text(
                context.tr(
                  'GNU GPL v3.0 and third-party notices',
                  'GNU GPL v3.0 与第三方声明',
                ),
              ),
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
                strings.faq,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (defaultTargetPlatform == TargetPlatform.android)
              _FaqTile(
                icon: Icons.play_circle_outline,
                question: context.tr(
                  'Which playback engine should I use?',
                  '我应该使用哪个播放引擎？',
                ),
                answer: context.tr(
                  'DreamPlayer offers two engines on Android:\n\n• Media3 (default) — hardware-accelerated, supports Dolby Vision, HDR10, HDR10+, and all audio codecs via FFmpeg. Best for most users.\n\n• libmpv — compatibility engine using FFmpeg. It handles some edge-case formats Media3 cannot decode, but does not support Dolby Vision or HDR passthrough.\n\nUse Media3 unless a specific file fails to play, then try libmpv from the error screen.',
                  'DreamPlayer 在 Android 上提供两种引擎：\n\n• Media3（默认）——硬件加速，支持杜比视界、HDR10、HDR10+，并通过 FFmpeg 支持各种音频编码，适合大多数用户。\n\n• libmpv——使用 FFmpeg 的兼容引擎，可处理部分 Media3 无法解码的特殊格式，但不支持杜比视界或 HDR 直通。\n\n建议优先使用 Media3；仅当特定文件播放失败时，再从错误页面尝试 libmpv。',
                ),
              ),
            _FaqTile(
              icon: Icons.refresh,
              question: context.tr(
                'How do I refresh network share listings?',
                '如何刷新网络共享列表？',
              ),
              answer: context.tr(
                'Pull down on any folder listing in SMB, WebDAV, FTP, DLNA, or Jellyfin to refresh. This is useful after adding, renaming, or deleting files on your NAS or PC.',
                '在 SMB、WebDAV、FTP、DLNA 或 Jellyfin 的任意文件夹列表中下拉即可刷新。在 NAS 或电脑上新增、重命名或删除文件后，可用此方式查看最新内容。',
              ),
            ),
            _FaqTile(
              icon: Icons.movie_filter,
              question: context.tr(
                'How should I name my files for TMDB metadata?',
                '如何命名文件以匹配 TMDB 元数据？',
              ),
              answer: context.tr(
                'DreamPlayer matches filenames with The Movie Database (TMDB) to fetch posters, titles, ratings, and other metadata.\n\nUse clean names for best results:\n  Dune (2021)\n  The Matrix 1999\n  Breaking Bad S01E01\n\nQuality and release tags such as 1080p, WEB-DL, and -RARBG are removed automatically before searching.\n\nTo correct a match manually, open the details screen, tap “Fix match”, and search TMDB.',
                'DreamPlayer 会根据文件名在 The Movie Database（TMDB）中匹配海报、标题、评分等元数据。\n\n使用简洁名称效果最佳：\n  Dune (2021)\n  The Matrix 1999\n  Breaking Bad S01E01\n\n搜索前会自动移除 1080p、WEB-DL、-RARBG 等画质和发布组标签。\n\n如需手动修正，请打开详情页，点击“修正匹配”，然后搜索 TMDB。',
              ),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
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
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              context.tr(
                'Synced ${items.length} item(s) to SIMKL',
                '已将 ${items.length} 项同步到 SIMKL',
              ),
            ),
          ),
        );
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
      title: Text(context.tr('Connect SIMKL', '连接 SIMKL')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr(
                'Go to the address below and enter this code:',
                '请打开以下地址并输入此代码：',
              ),
            ),
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
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_status)),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('Cancel', '取消')),
        ),
      ],
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
        leading: Icon(
          icon,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
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
