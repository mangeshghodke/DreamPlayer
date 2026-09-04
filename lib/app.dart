import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_localizations.dart';
import 'screens/home_screen.dart';
import 'screens/player_screen.dart';
import 'screens/settings_screen.dart';
import 'models/video_item.dart';
import 'services/jellyfin_client.dart';
import 'services/open_intent.dart';
import 'services/app_preferences.dart';
import 'theme/app_theme.dart';

/// Used by the "Open with" intent handler to navigate without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Route observer so screens (e.g. Home) can refresh when a pushed route above
/// them pops back (file browser → Home, player → Home, "Open with" → Home).
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

class DreamPlayerApp extends StatefulWidget {
  const DreamPlayerApp({super.key});

  @override
  State<DreamPlayerApp> createState() => _DreamPlayerAppState();
}

class _DreamPlayerAppState extends State<DreamPlayerApp> {
  @override
  void initState() {
    super.initState();
    _listenForIntents();
  }

  Future<void> _listenForIntents() async {
    final service = OpenIntentService.instance;
    service.intents.listen((intent) async {
      final navigator = appNavigatorKey.currentState;
      if (navigator == null) return;
      final base = intent.toVideoItem();
      // Jellyfin "Open in external player": the raw stream URL carries no
      // external subtitle tracks, so re-match it to a saved server + item and
      // attach the sidecars the same way in-app playback does. Best-effort —
      // falls back to the raw URL on any failure.
      final video = await _enrichIntentVideo(base);
      if (!mounted) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(video: video ?? base),
        ),
      );
    });
    // Fetches the intent that launched the app (if any).
    await service.init();
  }

  /// Enriches an "Open with" intent's bare [VideoItem] with Jellyfin external
  /// subtitles when its URI is a saved server's direct-play stream URL.
  /// Returns null (raw [video] plays untouched) when it isn't or on any error.
  Future<VideoItem?> _enrichIntentVideo(VideoItem video) async {
    final uri = video.uri;
    if (uri == null || !uri.startsWith('http')) return null;
    try {
      return await JellyfinClient().enrichJellyfinStreamVideoItem(
        url: uri,
        title: video.title,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppPreferencesController.instance,
      builder: (context, _) => MaterialApp(
        onGenerateTitle: (context) => AppLocalizations.of(context).appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: AppPreferencesController.instance.themeMode,
        locale: AppPreferencesController.instance.locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorKey: appNavigatorKey,
        navigatorObservers: [appRouteObserver],
        builder: (context, child) {
          final mediaQuery = MediaQuery.of(context);
          final clampedTextScaler = mediaQuery.textScaler.clamp(
            minScaleFactor: 1.0,
            maxScaleFactor: 1.3,
          );
          return MediaQuery(
            data: mediaQuery.copyWith(textScaler: clampedTextScaler),
            child: child!,
          );
        },
        home: const RootShell(),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _selectedIndex = 0;

  /// When the root back press happened, for the double-back-to-exit pattern.
  DateTime? _lastBackPress;

  /// Bumped whenever the Library tab is (re)selected so the Home screen can
  /// reload its "Continue watching" list even though IndexedStack keeps it
  /// alive (playing from the file browser/WebDAV never pushes through Home).
  final ValueNotifier<int> _homeRefreshTick = ValueNotifier(0);

  @override
  void dispose() {
    _homeRefreshTick.dispose();
    super.dispose();
  }

  /// Root-route back press: first tap shows a "Press back again to exit"
  /// snackbar; a second tap within 2 s exits the app. Back presses while any
  /// route is pushed above (player, browsers, dialogs) pop those normally and
  /// never reach this handler.
  void _handleRootBack() {
    final now = DateTime.now();
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).pressBackAgain),
            duration: const Duration(seconds: 2),
          ),
        );
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    // Android edge-to-edge reports `padding.top == 0` (transparent status
    // bar), so SliverAppBar/AppBar won't push content below the status bar.
    // Map the real status-bar inset (`viewPadding`) into `padding` for the
    // library/settings tabs so they never clash with the status bar.
    final padded = mediaQuery.copyWith(
      padding: mediaQuery.padding.copyWith(top: mediaQuery.viewPadding.top),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleRootBack();
      },
      child: Scaffold(
        body: MediaQuery(
          data: padded,
          child: IndexedStack(
            index: _selectedIndex,
            children: [
              HomeScreen(refreshTick: _homeRefreshTick),
              const SettingsScreen(),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (index) {
            setState(() {
              _selectedIndex = index;
            });
            if (index == 0) _homeRefreshTick.value++;
          },
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.video_library_outlined),
              selectedIcon: const Icon(Icons.video_library),
              label: AppLocalizations.of(context).library,
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: AppLocalizations.of(context).settings,
            ),
          ],
        ),
      ),
    );
  }
}
