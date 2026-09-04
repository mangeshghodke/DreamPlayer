import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'DreamPlayer'**
  String get appName;

  /// No description provided for @library.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get library;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get languageSystem;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageChinese.
  ///
  /// In en, this message translates to:
  /// **'Simplified Chinese'**
  String get languageChinese;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @remoteServers.
  ///
  /// In en, this message translates to:
  /// **'Remote servers'**
  String get remoteServers;

  /// No description provided for @noRemoteServers.
  ///
  /// In en, this message translates to:
  /// **'No saved remote servers'**
  String get noRemoteServers;

  /// No description provided for @configured.
  ///
  /// In en, this message translates to:
  /// **'Configured'**
  String get configured;

  /// No description provided for @signedIn.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get signedIn;

  /// No description provided for @signInRequired.
  ///
  /// In en, this message translates to:
  /// **'Sign-in required'**
  String get signInRequired;

  /// No description provided for @guest.
  ///
  /// In en, this message translates to:
  /// **'Guest'**
  String get guest;

  /// No description provided for @noLogin.
  ///
  /// In en, this message translates to:
  /// **'No login'**
  String get noLogin;

  /// No description provided for @selfSignedAllowed.
  ///
  /// In en, this message translates to:
  /// **'self-signed allowed'**
  String get selfSignedAllowed;

  /// No description provided for @yourLibrary.
  ///
  /// In en, this message translates to:
  /// **'Your library'**
  String get yourLibrary;

  /// No description provided for @continueWatching.
  ///
  /// In en, this message translates to:
  /// **'Continue watching'**
  String get continueWatching;

  /// No description provided for @nothingYet.
  ///
  /// In en, this message translates to:
  /// **'Nothing yet'**
  String get nothingYet;

  /// No description provided for @emptyLibraryHint.
  ///
  /// In en, this message translates to:
  /// **'Videos you play will appear here.'**
  String get emptyLibraryHint;

  /// No description provided for @noFoldersPhone.
  ///
  /// In en, this message translates to:
  /// **'No folders yet. Tap + to add one.'**
  String get noFoldersPhone;

  /// No description provided for @noFoldersTv.
  ///
  /// In en, this message translates to:
  /// **'No folders yet. Use the buttons above to add one.'**
  String get noFoldersTv;

  /// No description provided for @addSource.
  ///
  /// In en, this message translates to:
  /// **'Add a source'**
  String get addSource;

  /// No description provided for @addFolderToLibrary.
  ///
  /// In en, this message translates to:
  /// **'Add folder to library'**
  String get addFolderToLibrary;

  /// No description provided for @folderExamples.
  ///
  /// In en, this message translates to:
  /// **'A TV-show folder, a movie folder…'**
  String get folderExamples;

  /// No description provided for @internalStorage.
  ///
  /// In en, this message translates to:
  /// **'Internal storage'**
  String get internalStorage;

  /// No description provided for @browseDeviceFiles.
  ///
  /// In en, this message translates to:
  /// **'Browse files on this device'**
  String get browseDeviceFiles;

  /// No description provided for @networkSources.
  ///
  /// In en, this message translates to:
  /// **'Network sources'**
  String get networkSources;

  /// No description provided for @networkSourcesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Servers on this network'**
  String get networkSourcesSubtitle;

  /// No description provided for @smbNas.
  ///
  /// In en, this message translates to:
  /// **'SMB / NAS'**
  String get smbNas;

  /// No description provided for @smbAndroidSubtitle.
  ///
  /// In en, this message translates to:
  /// **'SMB shares on the local network'**
  String get smbAndroidSubtitle;

  /// No description provided for @smbIosSubtitle.
  ///
  /// In en, this message translates to:
  /// **'SMB via the Files app'**
  String get smbIosSubtitle;

  /// No description provided for @addWebDavServer.
  ///
  /// In en, this message translates to:
  /// **'Add a WebDAV server'**
  String get addWebDavServer;

  /// No description provided for @ftpServerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'FTP or SFTP file server'**
  String get ftpServerSubtitle;

  /// No description provided for @jellyfinServerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Jellyfin / Emby media server'**
  String get jellyfinServerSubtitle;

  /// No description provided for @dlnaSubtitle.
  ///
  /// In en, this message translates to:
  /// **'UPnP / DLNA servers on this network'**
  String get dlnaSubtitle;

  /// No description provided for @playUrl.
  ///
  /// In en, this message translates to:
  /// **'Play URL'**
  String get playUrl;

  /// No description provided for @playUrlSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Stream a direct video link'**
  String get playUrlSubtitle;

  /// No description provided for @videoUrl.
  ///
  /// In en, this message translates to:
  /// **'Video URL'**
  String get videoUrl;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @invalidHttpUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid http(s) URL'**
  String get invalidHttpUrl;

  /// No description provided for @pressBackAgain.
  ///
  /// In en, this message translates to:
  /// **'Press back again to exit'**
  String get pressBackAgain;

  /// No description provided for @up.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get up;

  /// No description provided for @serverList.
  ///
  /// In en, this message translates to:
  /// **'Server list'**
  String get serverList;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @addServer.
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get addServer;

  /// No description provided for @savedServers.
  ///
  /// In en, this message translates to:
  /// **'Saved servers'**
  String get savedServers;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @errorMessage.
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String errorMessage(String message);

  /// No description provided for @webDav.
  ///
  /// In en, this message translates to:
  /// **'WebDAV'**
  String get webDav;

  /// No description provided for @ftpSftp.
  ///
  /// In en, this message translates to:
  /// **'FTP / SFTP'**
  String get ftpSftp;

  /// No description provided for @jellyfin.
  ///
  /// In en, this message translates to:
  /// **'Jellyfin'**
  String get jellyfin;

  /// No description provided for @dlna.
  ///
  /// In en, this message translates to:
  /// **'DLNA'**
  String get dlna;

  /// No description provided for @support.
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get support;

  /// No description provided for @storage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storage;

  /// No description provided for @player.
  ///
  /// In en, this message translates to:
  /// **'Player'**
  String get player;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @faq.
  ///
  /// In en, this message translates to:
  /// **'FAQ'**
  String get faq;

  /// No description provided for @selectLanguage.
  ///
  /// In en, this message translates to:
  /// **'Select language'**
  String get selectLanguage;

  /// No description provided for @selectTheme.
  ///
  /// In en, this message translates to:
  /// **'Select theme'**
  String get selectTheme;

  /// No description provided for @nothingHere.
  ///
  /// In en, this message translates to:
  /// **'Nothing here'**
  String get nothingHere;

  /// No description provided for @bookmarkFolder.
  ///
  /// In en, this message translates to:
  /// **'Bookmark this folder to Home'**
  String get bookmarkFolder;

  /// No description provided for @bookmarkAdded.
  ///
  /// In en, this message translates to:
  /// **'Bookmarked {folder} to Home ({protocol} · {server})'**
  String bookmarkAdded(String folder, String protocol, String server);

  /// No description provided for @removedServer.
  ///
  /// In en, this message translates to:
  /// **'Removed {server}'**
  String removedServer(String server);

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @test.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get test;

  /// No description provided for @optional.
  ///
  /// In en, this message translates to:
  /// **'optional'**
  String get optional;

  /// No description provided for @serverName.
  ///
  /// In en, this message translates to:
  /// **'Server name'**
  String get serverName;

  /// No description provided for @name.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// No description provided for @host.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get host;

  /// No description provided for @port.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get port;

  /// No description provided for @path.
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get path;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @domain.
  ///
  /// In en, this message translates to:
  /// **'Domain'**
  String get domain;

  /// No description provided for @networkShares.
  ///
  /// In en, this message translates to:
  /// **'Network shares'**
  String get networkShares;

  /// No description provided for @scanNetwork.
  ///
  /// In en, this message translates to:
  /// **'Scan network'**
  String get scanNetwork;

  /// No description provided for @scanningNetwork.
  ///
  /// In en, this message translates to:
  /// **'Scanning your network…'**
  String get scanningNetwork;

  /// No description provided for @selfSignedCertificate.
  ///
  /// In en, this message translates to:
  /// **'Self-signed certificate'**
  String get selfSignedCertificate;

  /// No description provided for @addToLibrary.
  ///
  /// In en, this message translates to:
  /// **'Add to library'**
  String get addToLibrary;

  /// No description provided for @signedInTo.
  ///
  /// In en, this message translates to:
  /// **'Signed in to {server}'**
  String signedInTo(String server);

  /// No description provided for @addedToLibrary.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" added to your library'**
  String addedToLibrary(String name);

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signIn;

  /// No description provided for @editServer.
  ///
  /// In en, this message translates to:
  /// **'Edit server'**
  String get editServer;

  /// No description provided for @serverAddress.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get serverAddress;

  /// No description provided for @guestNoCredentials.
  ///
  /// In en, this message translates to:
  /// **'Guest — no username/password'**
  String get guestNoCredentials;

  /// No description provided for @detectedOnNetwork.
  ///
  /// In en, this message translates to:
  /// **'Detected on this network'**
  String get detectedOnNetwork;

  /// No description provided for @onThisNetwork.
  ///
  /// In en, this message translates to:
  /// **'On this network'**
  String get onThisNetwork;

  /// No description provided for @scanLocalNetwork.
  ///
  /// In en, this message translates to:
  /// **'Scan local network'**
  String get scanLocalNetwork;

  /// No description provided for @scanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get scanning;

  /// No description provided for @signedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as {username}'**
  String signedInAs(String username);

  /// No description provided for @notSignedIn.
  ///
  /// In en, this message translates to:
  /// **'Not signed in'**
  String get notSignedIn;

  /// No description provided for @clearCache.
  ///
  /// In en, this message translates to:
  /// **'Clear cache'**
  String get clearCache;

  /// No description provided for @audioPassthrough.
  ///
  /// In en, this message translates to:
  /// **'Audio passthrough'**
  String get audioPassthrough;

  /// No description provided for @swipeGestures.
  ///
  /// In en, this message translates to:
  /// **'Swipe gestures'**
  String get swipeGestures;

  /// No description provided for @pictureInPicture.
  ///
  /// In en, this message translates to:
  /// **'Picture-in-picture'**
  String get pictureInPicture;

  /// No description provided for @autoPlayNextEpisode.
  ///
  /// In en, this message translates to:
  /// **'Auto-play next episode'**
  String get autoPlayNextEpisode;

  /// No description provided for @onScreenBadges.
  ///
  /// In en, this message translates to:
  /// **'On-screen badges'**
  String get onScreenBadges;

  /// No description provided for @badgeOptions.
  ///
  /// In en, this message translates to:
  /// **'Badge options'**
  String get badgeOptions;

  /// No description provided for @volumeBoost.
  ///
  /// In en, this message translates to:
  /// **'Volume Boost'**
  String get volumeBoost;

  /// No description provided for @nightMode.
  ///
  /// In en, this message translates to:
  /// **'Night Mode'**
  String get nightMode;

  /// No description provided for @videoDecoder.
  ///
  /// In en, this message translates to:
  /// **'Video decoder'**
  String get videoDecoder;

  /// No description provided for @metadata.
  ///
  /// In en, this message translates to:
  /// **'Metadata'**
  String get metadata;

  /// No description provided for @tmdbApiKey.
  ///
  /// In en, this message translates to:
  /// **'TMDB API key'**
  String get tmdbApiKey;

  /// No description provided for @subtitles.
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get subtitles;

  /// No description provided for @subtitleReadingLanguage.
  ///
  /// In en, this message translates to:
  /// **'Subtitle reading language'**
  String get subtitleReadingLanguage;

  /// No description provided for @subtitleDownloadLanguage.
  ///
  /// In en, this message translates to:
  /// **'Subtitle download language'**
  String get subtitleDownloadLanguage;

  /// No description provided for @subtitleEncoding.
  ///
  /// In en, this message translates to:
  /// **'Subtitle encoding'**
  String get subtitleEncoding;

  /// No description provided for @autoFetchSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Auto-fetch subtitles'**
  String get autoFetchSubtitles;

  /// No description provided for @engine.
  ///
  /// In en, this message translates to:
  /// **'Engine'**
  String get engine;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @openSourceLicenses.
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get openSourceLicenses;

  /// No description provided for @noSharesFound.
  ///
  /// In en, this message translates to:
  /// **'No shares found. Check your NAS share settings and make sure shares are visible to the network.'**
  String get noSharesFound;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
