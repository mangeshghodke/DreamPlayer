import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_ru.dart';
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
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

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
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('ru'),
    Locale('zh')
  ];

  /// Cancel button
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// Save button
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// Delete button
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// Remove button
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get commonRemove;

  /// Close button
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// Retry button
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// Edit button
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get commonEdit;

  /// Search button/label
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get commonSearch;

  /// Test connection button
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get commonTest;

  /// Disabled/off state
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get commonOff;

  /// Reset to defaults
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get commonReset;

  /// Clear action
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get commonClear;

  /// Network discovery button
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get commonDiscover;

  /// Refresh/reload button
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get commonRefresh;

  /// Retry a failed operation
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetryAction;

  /// Empty state message
  ///
  /// In en, this message translates to:
  /// **'Nothing here'**
  String get commonNothingHere;

  /// Empty list message
  ///
  /// In en, this message translates to:
  /// **'Nothing yet'**
  String get commonNothingYet;

  /// Generic error message
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get commonSomethingWentWrong;

  /// No search results
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get commonNoResults;

  /// Test server connection button
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get commonTestConnection;

  /// App name shown in launcher and headers
  ///
  /// In en, this message translates to:
  /// **'DreamPlayer'**
  String get appTitle;

  /// Bottom nav tab label
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get navLibrary;

  /// Bottom nav tab label
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// Toast message when back is pressed once
  ///
  /// In en, this message translates to:
  /// **'Press back again to exit'**
  String get pressBackToExit;

  /// Section header for resume list
  ///
  /// In en, this message translates to:
  /// **'Continue watching'**
  String get homeContinueWatching;

  /// Section header for user library folders
  ///
  /// In en, this message translates to:
  /// **'Your library'**
  String get homeYourLibrary;

  /// FAB menu label
  ///
  /// In en, this message translates to:
  /// **'Add a source'**
  String get homeAddSource;

  /// Menu item to add a local folder
  ///
  /// In en, this message translates to:
  /// **'Add folder to library'**
  String get homeAddFolder;

  /// Menu item for local file browser
  ///
  /// In en, this message translates to:
  /// **'Internal storage'**
  String get homeInternalStorage;

  /// Subtitle for internal storage menu item
  ///
  /// In en, this message translates to:
  /// **'Browse files on this device'**
  String get homeBrowseFiles;

  /// Expansion tile header for network options
  ///
  /// In en, this message translates to:
  /// **'Network sources'**
  String get homeNetworkSources;

  /// Empty library state
  ///
  /// In en, this message translates to:
  /// **'No folders yet. Use the buttons above to add one.'**
  String get homeNoFolders;

  /// Empty continue-watching state
  ///
  /// In en, this message translates to:
  /// **'Videos you play will appear here.'**
  String get homeNoVideos;

  /// Authorization dialog title
  ///
  /// In en, this message translates to:
  /// **'Authorization'**
  String get homeAuthorization;

  /// Error when SAF picker times out
  ///
  /// In en, this message translates to:
  /// **'The folder picker timed out. Please try again.'**
  String get homeFolderPickerTimeout;

  /// Error when folder picker fails
  ///
  /// In en, this message translates to:
  /// **'Could not pick a folder'**
  String get homeCouldNotPickFolder;

  /// Dialog title for removing library folder
  ///
  /// In en, this message translates to:
  /// **'Remove from library?'**
  String get homeRemoveFromLibrary;

  /// Dialog body for library removal
  ///
  /// In en, this message translates to:
  /// **'The files stay on your device.'**
  String get homeFilesStayOnDevice;

  /// Dialog title for removing continue-watching entry
  ///
  /// In en, this message translates to:
  /// **'Remove from Continue watching?'**
  String get homeRemoveFromContinue;

  /// Section header for active downloads in drawer
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get homeDownloading;

  /// Section header for completed downloads in drawer
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get homeDownloads;

  /// Empty downloads state
  ///
  /// In en, this message translates to:
  /// **'No downloads yet'**
  String get homeNoDownloads;

  /// No finished downloads in drawer
  ///
  /// In en, this message translates to:
  /// **'No completed downloads'**
  String get homeNoCompletedDownloads;

  /// Download status label
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get homeCancelled;

  /// Download status label
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get homeFailed;

  /// Dialog title for removing a download
  ///
  /// In en, this message translates to:
  /// **'Remove download?'**
  String get homeRemoveDownload;

  /// Menu item to play a direct URL
  ///
  /// In en, this message translates to:
  /// **'Play URL'**
  String get homePlayUrl;

  /// Subtitle for Play URL menu item
  ///
  /// In en, this message translates to:
  /// **'Stream a direct video link'**
  String get homeStreamLink;

  /// Text field label for URL input
  ///
  /// In en, this message translates to:
  /// **'Video URL'**
  String get homeVideoUrl;

  /// Validation error for URL input
  ///
  /// In en, this message translates to:
  /// **'Enter a valid http(s) URL'**
  String get homeEnterValidUrl;

  /// Error opening a URL
  ///
  /// In en, this message translates to:
  /// **'Could not open this link'**
  String get homeCouldNotOpenLink;

  /// Menu item for WebDAV
  ///
  /// In en, this message translates to:
  /// **'Add a WebDAV server'**
  String get homeAddWebdavServer;

  /// Subtitle for FTP menu item
  ///
  /// In en, this message translates to:
  /// **'FTP or SFTP file server'**
  String get homeFtpOrSftp;

  /// Subtitle for Jellyfin menu item
  ///
  /// In en, this message translates to:
  /// **'Jellyfin / Emby media server'**
  String get homeJellyfinServer;

  /// Subtitle for DLNA menu item
  ///
  /// In en, this message translates to:
  /// **'UPnP / DLNA servers on this network'**
  String get homeUpnpDlna;

  /// Menu item for SMB shares
  ///
  /// In en, this message translates to:
  /// **'SMB / NAS'**
  String get homeSmbNas;

  /// Subtitle for SMB menu item on Android
  ///
  /// In en, this message translates to:
  /// **'SMB shares on the local network'**
  String get homeSmbShares;

  /// Subtitle for SMB on iOS via Files
  ///
  /// In en, this message translates to:
  /// **'SMB via the Files app'**
  String get homeSmbViaFiles;

  /// Shown on unsupported platforms
  ///
  /// In en, this message translates to:
  /// **'Playback is not yet supported on this platform.'**
  String get playerNotSupported;

  /// Error when no URI/path
  ///
  /// In en, this message translates to:
  /// **'No video source provided.'**
  String get playerNoSource;

  /// Error when source can't play
  ///
  /// In en, this message translates to:
  /// **'No playable source for this video.'**
  String get playerNoPlayable;

  /// Error when mpv can't open SMB
  ///
  /// In en, this message translates to:
  /// **'Could not stream this SMB file through the fallback engine.'**
  String get playerSmbStreamError;

  /// Error when controller disposed early
  ///
  /// In en, this message translates to:
  /// **'Video controller lost before surface attach.'**
  String get playerControllerLost;

  /// Audio track picker title
  ///
  /// In en, this message translates to:
  /// **'Audio tracks'**
  String get playerAudioTracks;

  /// No audio tracks available
  ///
  /// In en, this message translates to:
  /// **'No audio tracks found'**
  String get playerNoAudioTracks;

  /// Subtitle picker section title
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get playerSubtitles;

  /// No subtitle tracks available
  ///
  /// In en, this message translates to:
  /// **'No subtitles found in this video'**
  String get playerNoSubtitles;

  /// Button to search OpenSubtitles
  ///
  /// In en, this message translates to:
  /// **'Search online subtitles…'**
  String get playerSearchOnlineSubs;

  /// Button to load external subtitle file
  ///
  /// In en, this message translates to:
  /// **'Load subtitle file…'**
  String get playerLoadSubtitleFile;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get playerTitle;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get playerSource;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get playerUrl;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'File size'**
  String get playerFileSize;

  /// Button to open video info sheet
  ///
  /// In en, this message translates to:
  /// **'Video info'**
  String get playerVideoInfo;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'Resolution'**
  String get playerResolution;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'Decoder'**
  String get playerDecoder;

  /// Audio channels label
  ///
  /// In en, this message translates to:
  /// **'Audio ch.'**
  String get playerAudioCh;

  /// Info sheet row label for server transcoding
  ///
  /// In en, this message translates to:
  /// **'Stream'**
  String get playerStream;

  /// Shown when server is transcoding
  ///
  /// In en, this message translates to:
  /// **'Server transcoding'**
  String get playerServerTranscoding;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'Spatial audio'**
  String get playerSpatialAudio;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'Volume boost'**
  String get playerVolumeBoost;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'Night mode'**
  String get playerNightMode;

  /// Info sheet row label
  ///
  /// In en, this message translates to:
  /// **'Bass boost'**
  String get playerBassBoost;

  /// Playback speed info label
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get playerSpeed;

  /// Chapters section label
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get playerChapters;

  /// Aspect ratio picker title
  ///
  /// In en, this message translates to:
  /// **'Aspect ratio'**
  String get playerAspectRatio;

  /// Speed picker title
  ///
  /// In en, this message translates to:
  /// **'Playback speed'**
  String get playerPlaybackSpeed;

  /// ⋮ sheet section header
  ///
  /// In en, this message translates to:
  /// **'Playback settings'**
  String get playerPlaybackSettings;

  /// Repeat and shuffle section title
  ///
  /// In en, this message translates to:
  /// **'Repeat & shuffle'**
  String get playerRepeatShuffle;

  /// Shuffle toggle label
  ///
  /// In en, this message translates to:
  /// **'Shuffle'**
  String get playerShuffle;

  /// Shuffle subtitle
  ///
  /// In en, this message translates to:
  /// **'Random order inside the folder'**
  String get playerShuffleDesc;

  /// Sleep timer section title
  ///
  /// In en, this message translates to:
  /// **'Sleep timer'**
  String get playerSleepTimer;

  /// Sleep timer option
  ///
  /// In en, this message translates to:
  /// **'End of current video'**
  String get playerSleepEndOfVideo;

  /// Audio delay section title
  ///
  /// In en, this message translates to:
  /// **'Audio delay'**
  String get playerAudioDelay;

  /// Subtitle settings button
  ///
  /// In en, this message translates to:
  /// **'Subtitle settings'**
  String get playerSubtitleSettings;

  /// Subtitle settings subtitle
  ///
  /// In en, this message translates to:
  /// **'Size, color, background, delay'**
  String get playerSubtitleSettingsDesc;

  /// Decoder picker title
  ///
  /// In en, this message translates to:
  /// **'Video decoder'**
  String get playerVideoDecoder;

  /// Hardware-only decoder option
  ///
  /// In en, this message translates to:
  /// **'Force hardware decoders'**
  String get playerDecoderHw;

  /// Software decoder option
  ///
  /// In en, this message translates to:
  /// **'Prefer software decoders'**
  String get playerDecoderSw;

  /// Auto decoder option
  ///
  /// In en, this message translates to:
  /// **'Automatic (recommended)'**
  String get playerDecoderAuto;

  /// Subtitle under decoder picker
  ///
  /// In en, this message translates to:
  /// **'Reopens at same position to switch decoder.'**
  String get playerDecoderReopen;

  /// Volume boost section title
  ///
  /// In en, this message translates to:
  /// **'Volume Boost'**
  String get playerVolumeBoostTitle;

  /// Bass boost section title
  ///
  /// In en, this message translates to:
  /// **'Bass Boost'**
  String get playerBassBoostTitle;

  /// Bass boost level
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get playerBassLow;

  /// Bass boost level
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get playerBassMedium;

  /// Bass boost level
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get playerBassHigh;

  /// Night mode section title
  ///
  /// In en, this message translates to:
  /// **'Night Mode'**
  String get playerNightModeTitle;

  /// Auto-play toggle label
  ///
  /// In en, this message translates to:
  /// **'Auto-play next'**
  String get playerAutoPlayNext;

  /// Auto-play subtitle
  ///
  /// In en, this message translates to:
  /// **'Play the next episode when one ends'**
  String get playerAutoPlayNextDesc;

  /// Subtitle delay slider label
  ///
  /// In en, this message translates to:
  /// **'Subtitle delay'**
  String get playerSubtitleDelay;

  /// Download button in ⋮ sheet
  ///
  /// In en, this message translates to:
  /// **'Download to device'**
  String get playerDownloadToDevice;

  /// External player handoff button
  ///
  /// In en, this message translates to:
  /// **'Open in external player'**
  String get playerOpenExternal;

  /// Empty folder state
  ///
  /// In en, this message translates to:
  /// **'No videos or folders here'**
  String get playerNoVideoInFolder;

  /// Fallback engine button on error surface
  ///
  /// In en, this message translates to:
  /// **'Try with MPV'**
  String get playerTryMpv;

  /// Replay from start button
  ///
  /// In en, this message translates to:
  /// **'Watch from beginning'**
  String get playerWatchBeginning;

  /// Replay from start via MPV
  ///
  /// In en, this message translates to:
  /// **'Watch from beginning (MPV)'**
  String get playerWatchBeginningMpv;

  /// Play via MPV engine button
  ///
  /// In en, this message translates to:
  /// **'Play with MPV'**
  String get playerPlayWithMpv;

  /// Chapter count label
  ///
  /// In en, this message translates to:
  /// **'{count} chapters'**
  String playerChapterN(int count);

  /// Current position label
  ///
  /// In en, this message translates to:
  /// **'Pos: {position}'**
  String playerPosition(String position);

  /// Volume multiplier display
  ///
  /// In en, this message translates to:
  /// **'{level}×'**
  String playerVolumeLevel(String level);

  /// Source badge label
  ///
  /// In en, this message translates to:
  /// **'Jellyfin'**
  String get sourceJellyfin;

  /// Source badge label
  ///
  /// In en, this message translates to:
  /// **'Jellyfin (HTTP)'**
  String get sourceJellyfinHttp;

  /// Source badge label
  ///
  /// In en, this message translates to:
  /// **'Network (HTTP)'**
  String get sourceNetworkHttp;

  /// Source badge label
  ///
  /// In en, this message translates to:
  /// **'WebDAV'**
  String get sourceWebdav;

  /// Source badge label
  ///
  /// In en, this message translates to:
  /// **'Local file'**
  String get sourceLocalFile;

  /// Source badge label
  ///
  /// In en, this message translates to:
  /// **'Document (SAF)'**
  String get sourceDocumentSaf;

  /// Source badge label
  ///
  /// In en, this message translates to:
  /// **'FTP/SFTP'**
  String get sourceFtpSftp;

  /// Source badge label
  ///
  /// In en, this message translates to:
  /// **'SMB'**
  String get sourceSmb;

  /// Source badge label
  ///
  /// In en, this message translates to:
  /// **'App asset'**
  String get sourceAppAsset;

  /// Transcoding badge
  ///
  /// In en, this message translates to:
  /// **'Transcoding'**
  String get sourceTranscoding;

  /// Software decode chip
  ///
  /// In en, this message translates to:
  /// **'SW decode'**
  String get sourceSwDecode;

  /// Hardware decode chip
  ///
  /// In en, this message translates to:
  /// **'HW decode'**
  String get sourceHwDecode;

  /// Auto hardware decode chip
  ///
  /// In en, this message translates to:
  /// **'HW decode (auto)'**
  String get sourceHwDecodeAuto;

  /// Settings section header
  ///
  /// In en, this message translates to:
  /// **'Player'**
  String get settingsPlayer;

  /// Settings section header
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get settingsAudio;

  /// Settings section header
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get settingsStorage;

  /// Settings section header
  ///
  /// In en, this message translates to:
  /// **'Metadata'**
  String get settingsMetadata;

  /// Settings section header
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get settingsSubtitles;

  /// Settings section header
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// Settings section header
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get settingsSupport;

  /// Toggle for swipe brightness/volume
  ///
  /// In en, this message translates to:
  /// **'Swipe gestures'**
  String get settingsSwipeGestures;

  /// Swipe gestures subtitle
  ///
  /// In en, this message translates to:
  /// **'Swipe left side for brightness, right side for volume'**
  String get settingsSwipeDesc;

  /// PiP toggle label
  ///
  /// In en, this message translates to:
  /// **'Picture-in-picture'**
  String get settingsPip;

  /// PiP subtitle
  ///
  /// In en, this message translates to:
  /// **'Keep playing in a floating window when you leave the app'**
  String get settingsPipDesc;

  /// Default playback engine setting
  ///
  /// In en, this message translates to:
  /// **'Default playback engine'**
  String get settingsDefaultEngine;

  /// Auto engine subtitle
  ///
  /// In en, this message translates to:
  /// **'Start with Media3, auto-fallback to libmpv if it fails'**
  String get settingsEngineAutoDesc;

  /// Media3 engine subtitle
  ///
  /// In en, this message translates to:
  /// **'Hardware-accelerated, supports Dolby Vision / HDR'**
  String get settingsEngineMedia3Desc;

  /// libmpv engine subtitle
  ///
  /// In en, this message translates to:
  /// **'Software-first, handles more codecs (SDR only)'**
  String get settingsEngineMpvDesc;

  /// Ask-every-time engine subtitle
  ///
  /// In en, this message translates to:
  /// **'Show both options on every video'**
  String get settingsEngineAskDesc;

  /// Auto-play toggle label
  ///
  /// In en, this message translates to:
  /// **'Auto-play next episode'**
  String get settingsAutoPlayNext;

  /// Auto play next description
  ///
  /// In en, this message translates to:
  /// **'Play the next episode when one ends'**
  String get settingsAutoPlayNextDesc;

  /// Badge toggle label
  ///
  /// In en, this message translates to:
  /// **'On-screen badges'**
  String get settingsOnScreenBadges;

  /// Badges subtitle
  ///
  /// In en, this message translates to:
  /// **'Show format chips on screen while playing'**
  String get settingsBadgesDesc;

  /// Badge options title
  ///
  /// In en, this message translates to:
  /// **'Badge options'**
  String get settingsBadgeOptions;

  /// Badge dialog subtitle
  ///
  /// In en, this message translates to:
  /// **'Choose which chips to show'**
  String get settingsChooseBadges;

  /// Badge option label
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get settingsBadgeFormat;

  /// Badge option label
  ///
  /// In en, this message translates to:
  /// **'Audio codec'**
  String get settingsBadgeAudioCodec;

  /// Badge option label
  ///
  /// In en, this message translates to:
  /// **'Video codec'**
  String get settingsBadgeVideoCodec;

  /// Badge option subtitle
  ///
  /// In en, this message translates to:
  /// **'HEVC / H.264 / AV1'**
  String get settingsBadgeVideoCodecDesc;

  /// Badge option label
  ///
  /// In en, this message translates to:
  /// **'Resolution'**
  String get settingsBadgeResolution;

  /// Badge option label
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get settingsBadgePlayback;

  /// Badge option label
  ///
  /// In en, this message translates to:
  /// **'Spatial audio'**
  String get settingsBadgeSpatialAudio;

  /// Badge option label
  ///
  /// In en, this message translates to:
  /// **'Server transcoding'**
  String get settingsBadgeTranscoding;

  /// Badge option label
  ///
  /// In en, this message translates to:
  /// **'Decoder'**
  String get settingsBadgeDecoder;

  /// Badge option subtitle
  ///
  /// In en, this message translates to:
  /// **'HW / SW / auto'**
  String get settingsBadgeDecoderDesc;

  /// Volume boost section title
  ///
  /// In en, this message translates to:
  /// **'Volume Boost'**
  String get settingsVolumeBoost;

  /// Night mode section title
  ///
  /// In en, this message translates to:
  /// **'Night Mode'**
  String get settingsNightMode;

  /// Night mode subtitle
  ///
  /// In en, this message translates to:
  /// **'Compress dynamic range for quiet listening'**
  String get settingsNightModeDesc;

  /// Decoder picker label
  ///
  /// In en, this message translates to:
  /// **'Video decoder'**
  String get settingsVideoDecoder;

  /// Hardware-only option
  ///
  /// In en, this message translates to:
  /// **'Force hardware decoders'**
  String get settingsDecoderHw;

  /// Software option
  ///
  /// In en, this message translates to:
  /// **'Prefer software decoders'**
  String get settingsDecoderSw;

  /// Auto option
  ///
  /// In en, this message translates to:
  /// **'Let the system choose (recommended)'**
  String get settingsDecoderAuto;

  /// Subtitle under decoder picker
  ///
  /// In en, this message translates to:
  /// **'Takes effect on next video'**
  String get settingsDecoderReopen;

  /// TMDB key input label
  ///
  /// In en, this message translates to:
  /// **'TMDB API key'**
  String get settingsTmdbKey;

  /// Text field hint
  ///
  /// In en, this message translates to:
  /// **'API key (v3 auth)'**
  String get settingsApiKeyHint;

  /// Validation error
  ///
  /// In en, this message translates to:
  /// **'Key must be 32 characters'**
  String get settingsKeyMustBe32;

  /// Clear cache button
  ///
  /// In en, this message translates to:
  /// **'Clear cache'**
  String get settingsClearCache;

  /// Cache clear confirmation dialog
  ///
  /// In en, this message translates to:
  /// **'Clear cache?'**
  String get settingsClearCacheTitle;

  /// Cache cleared snackbar
  ///
  /// In en, this message translates to:
  /// **'Cache cleared'**
  String get settingsCacheCleared;

  /// Cache cleared subtitle
  ///
  /// In en, this message translates to:
  /// **'Cached images and temporary files cleared'**
  String get settingsCacheClearedDesc;

  /// Button to view licenses
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get settingsOpenLicenses;

  /// License section subtitle
  ///
  /// In en, this message translates to:
  /// **'GNU GPL v3.0 and third-party notices'**
  String get settingsGplNotices;

  /// Engine label in About section
  ///
  /// In en, this message translates to:
  /// **'Engine'**
  String get settingsEngine;

  /// Version label in About section
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get settingsVersion;

  /// FAQ section header
  ///
  /// In en, this message translates to:
  /// **'FAQ'**
  String get settingsFaq;

  /// FAQ question
  ///
  /// In en, this message translates to:
  /// **'Which playback engine should I use?'**
  String get settingsFaqEngine;

  /// FAQ answer
  ///
  /// In en, this message translates to:
  /// **'Use Media3 unless a specific file fails to play, in which case try MPV as a fallback.'**
  String get settingsFaqEngineAnswer;

  /// FAQ question
  ///
  /// In en, this message translates to:
  /// **'How do I refresh network share listings?'**
  String get settingsFaqRefresh;

  /// FAQ answer
  ///
  /// In en, this message translates to:
  /// **'Pull down on any folder listing in SMB, WebDAV, FTP, DLNA, or Jellyfin to refresh.'**
  String get settingsFaqRefreshAnswer;

  /// FAQ question
  ///
  /// In en, this message translates to:
  /// **'How should I name my files for TMDB metadata?'**
  String get settingsFaqTmdb;

  /// FAQ answer
  ///
  /// In en, this message translates to:
  /// **'DreamPlayer tries to match filenames against The Movie Database (TMDB) to fetch posters, titles, ratings, and more. Name files like \'Movie.Name.2024.1080p.mkv\' for best results.'**
  String get settingsFaqTmdbAnswer;

  /// SIMKL sync button
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get settingsSimklSync;

  /// SIMKL disconnect button
  ///
  /// In en, this message translates to:
  /// **'Disconnect SIMKL'**
  String get settingsSimklDisconnect;

  /// SIMKL disconnect subtitle
  ///
  /// In en, this message translates to:
  /// **'Sign out and stop syncing'**
  String get settingsSimklDisconnectDesc;

  /// SIMKL connect button
  ///
  /// In en, this message translates to:
  /// **'Connect SIMKL'**
  String get settingsSimklConnect;

  /// SIMKL not set up
  ///
  /// In en, this message translates to:
  /// **'SIMKL not configured'**
  String get settingsSimklNotConfigured;

  /// Error when not signed in
  ///
  /// In en, this message translates to:
  /// **'Sign in to SIMKL first'**
  String get settingsSimklSignInFirst;

  /// SIMKL sync description
  ///
  /// In en, this message translates to:
  /// **'Sync watched history with simkl.com (free unlimited)'**
  String get settingsSyncWatched;

  /// SIMKL auth instruction
  ///
  /// In en, this message translates to:
  /// **'Go to the address below and enter this code:'**
  String get settingsGoToAddress;

  /// SIMKL auth waiting state
  ///
  /// In en, this message translates to:
  /// **'Waiting for authorization…'**
  String get settingsWaitingAuth;

  /// SIMKL connected state
  ///
  /// In en, this message translates to:
  /// **'Connected!'**
  String get settingsConnected;

  /// OpenSubtitles section header
  ///
  /// In en, this message translates to:
  /// **'OpenSubtitles'**
  String get settingsOpenSubtitles;

  /// Subtitle reading language setting
  ///
  /// In en, this message translates to:
  /// **'Subtitle reading language'**
  String get settingsSubReadingLang;

  /// Subtitle download language setting
  ///
  /// In en, this message translates to:
  /// **'Subtitle download language'**
  String get settingsSubDownloadLang;

  /// Subtitle encoding setting
  ///
  /// In en, this message translates to:
  /// **'Subtitle encoding'**
  String get settingsSubEncoding;

  /// Auto-fetch toggle label
  ///
  /// In en, this message translates to:
  /// **'Auto-fetch subtitles'**
  String get settingsAutoFetchSubs;

  /// Auto-fetch subtitle
  ///
  /// In en, this message translates to:
  /// **'Download best match when no subtitles found'**
  String get settingsAutoFetchDesc;

  /// Audio passthrough toggle
  ///
  /// In en, this message translates to:
  /// **'Audio passthrough'**
  String get settingsAudioPassthrough;

  /// OpenSubtitles login dialog title
  ///
  /// In en, this message translates to:
  /// **'OpenSubtitles sign in'**
  String get settingsOpenSubtitlesSignIn;

  /// Username field label
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get settingsUsername;

  /// Password field label
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get settingsPassword;

  /// Resume button label
  ///
  /// In en, this message translates to:
  /// **'Resume from {time}'**
  String detailsResumeFrom(String time);

  /// Play button
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get detailsPlay;

  /// Play with engine suffix
  ///
  /// In en, this message translates to:
  /// **'Play{engineSuffix}'**
  String detailsPlayEngine(String engineSuffix);

  /// Replay from start
  ///
  /// In en, this message translates to:
  /// **'Watch from beginning'**
  String get detailsWatchBeginning;

  /// Manual TMDB search button
  ///
  /// In en, this message translates to:
  /// **'Find on TMDB'**
  String get detailsFindOnTmdb;

  /// Open info/search dialog
  ///
  /// In en, this message translates to:
  /// **'Get Info'**
  String get detailsGetInfo;

  /// No TMDB match state
  ///
  /// In en, this message translates to:
  /// **'No metadata loaded'**
  String get detailsNoMetadata;

  /// Re-search TMDB button
  ///
  /// In en, this message translates to:
  /// **'Fix match'**
  String get detailsFixMatch;

  /// Clear TMDB match button
  ///
  /// In en, this message translates to:
  /// **'Remove info'**
  String get detailsRemoveInfo;

  /// Overview section header
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get detailsOverview;

  /// Episode overview header
  ///
  /// In en, this message translates to:
  /// **'Episode overview'**
  String get detailsEpisodeOverview;

  /// Cast section header
  ///
  /// In en, this message translates to:
  /// **'Cast'**
  String get detailsCast;

  /// Episode cast header
  ///
  /// In en, this message translates to:
  /// **'Episode cast'**
  String get detailsEpisodeCast;

  /// Guest stars header
  ///
  /// In en, this message translates to:
  /// **'Guest stars'**
  String get detailsGuestStars;

  /// Episodes section header
  ///
  /// In en, this message translates to:
  /// **'Episodes'**
  String get detailsEpisodes;

  /// Stills gallery header
  ///
  /// In en, this message translates to:
  /// **'Stills'**
  String get detailsStills;

  /// Trailers section header
  ///
  /// In en, this message translates to:
  /// **'Trailers'**
  String get detailsTrailers;

  /// Subtitles card title
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get detailsSubtitles;

  /// Subtitle search button
  ///
  /// In en, this message translates to:
  /// **'Search subtitles online'**
  String get detailsSearchSubsOnline;

  /// File info card title
  ///
  /// In en, this message translates to:
  /// **'File info'**
  String get detailsFileInfo;

  /// Loading state while probing
  ///
  /// In en, this message translates to:
  /// **'Probing file…'**
  String get detailsProbingFile;

  /// Download button in details
  ///
  /// In en, this message translates to:
  /// **'Download to device'**
  String get detailsDownloadToDevice;

  /// Download complete label
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get detailsDownloaded;

  /// Search field hint in Fix match dialog
  ///
  /// In en, this message translates to:
  /// **'Search title'**
  String get detailsSearchTitle;

  /// Media type badge
  ///
  /// In en, this message translates to:
  /// **'TV Series'**
  String get detailsTvSeries;

  /// Media type badge
  ///
  /// In en, this message translates to:
  /// **'Movie'**
  String get detailsMovie;

  /// TMDB search error
  ///
  /// In en, this message translates to:
  /// **'Search is unavailable right now. Try again in a moment.'**
  String get detailsSearchUnavailable;

  /// TMDB search error
  ///
  /// In en, this message translates to:
  /// **'Search failed. Try again in a moment.'**
  String get detailsSearchFailed;

  /// No TMDB results
  ///
  /// In en, this message translates to:
  /// **'No results. Try a different title.'**
  String get detailsNoResults;

  /// Folder listing error
  ///
  /// In en, this message translates to:
  /// **'Could not list this folder'**
  String get detailsCouldNotListFolder;

  /// SIMKL sync button
  ///
  /// In en, this message translates to:
  /// **'Mark watched from SIMKL'**
  String get detailsMarkWatchedSimkl;

  /// SIMKL sync empty state
  ///
  /// In en, this message translates to:
  /// **'Nothing new from SIMKL'**
  String get detailsNothingNewSimkl;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Jan'**
  String get detailsMonthJan;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Feb'**
  String get detailsMonthFeb;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Mar'**
  String get detailsMonthMar;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Apr'**
  String get detailsMonthApr;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'May'**
  String get detailsMonthMay;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Jun'**
  String get detailsMonthJun;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Jul'**
  String get detailsMonthJul;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Aug'**
  String get detailsMonthAug;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Sep'**
  String get detailsMonthSep;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Oct'**
  String get detailsMonthOct;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Nov'**
  String get detailsMonthNov;

  /// Month abbreviation
  ///
  /// In en, this message translates to:
  /// **'Dec'**
  String get detailsMonthDec;

  /// SMB browser title
  ///
  /// In en, this message translates to:
  /// **'Network shares'**
  String get smbNetworkShares;

  /// Bookmark button in AppBar
  ///
  /// In en, this message translates to:
  /// **'Bookmark this folder to Home'**
  String get smbBookmarkHome;

  /// SIMKL sync button
  ///
  /// In en, this message translates to:
  /// **'Sync watched from SIMKL'**
  String get smbSyncSimkl;

  /// Server list button
  ///
  /// In en, this message translates to:
  /// **'Server list'**
  String get smbServerList;

  /// Network scan button
  ///
  /// In en, this message translates to:
  /// **'Scan network'**
  String get smbScanNetwork;

  /// Add SMB server button
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get smbAddServer;

  /// No shares found error
  ///
  /// In en, this message translates to:
  /// **'No shares found. Check your NAS share settings.'**
  String get smbNoShares;

  /// Episodes section in series view
  ///
  /// In en, this message translates to:
  /// **'Episodes'**
  String get smbEpisodes;

  /// Non-episode videos section
  ///
  /// In en, this message translates to:
  /// **'Other videos'**
  String get smbOtherVideos;

  /// Series overview header
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get smbOverview;

  /// Network scan loading state
  ///
  /// In en, this message translates to:
  /// **'Scanning your network…'**
  String get smbScanningNetwork;

  /// Discovered servers section
  ///
  /// In en, this message translates to:
  /// **'Detected on this network'**
  String get smbDetectedNetwork;

  /// Saved servers section
  ///
  /// In en, this message translates to:
  /// **'Saved servers'**
  String get smbSavedServers;

  /// Connection success message
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get smbConnected;

  /// Validation error
  ///
  /// In en, this message translates to:
  /// **'Host is required'**
  String get smbHostRequired;

  /// Save error message
  ///
  /// In en, this message translates to:
  /// **'Save failed'**
  String get smbSaveFailed;

  /// Edit server dialog title
  ///
  /// In en, this message translates to:
  /// **'Edit server'**
  String get smbEditServer;

  /// SMB dialog section label
  ///
  /// In en, this message translates to:
  /// **'SMB / network share'**
  String get smbNetworkShare;

  /// Server name field label
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get smbName;

  /// Host field label
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get smbHost;

  /// Port field label
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get smbPort;

  /// Username field label
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get smbUsername;

  /// Password field label
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get smbPassword;

  /// Password field hint on edit
  ///
  /// In en, this message translates to:
  /// **'Password (leave empty to keep)'**
  String get smbPasswordKeep;

  /// Domain field label
  ///
  /// In en, this message translates to:
  /// **'Domain'**
  String get smbDomain;

  /// Domain field hint
  ///
  /// In en, this message translates to:
  /// **'WORKGROUP'**
  String get smbDomainHint;

  /// Guest access label
  ///
  /// In en, this message translates to:
  /// **'Guest — no username/password'**
  String get smbGuest;

  /// Bookmark success message
  ///
  /// In en, this message translates to:
  /// **'Bookmarked {folder} to Home (SMB · {server})'**
  String smbBookmarkAdded(String folder, String server);

  /// Bookmark button in AppBar
  ///
  /// In en, this message translates to:
  /// **'Bookmark this folder to Home'**
  String get webdavBookmarkHome;

  /// Server list button
  ///
  /// In en, this message translates to:
  /// **'Server list'**
  String get webdavServerList;

  /// Add WebDAV server button
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get webdavAddServer;

  /// Saved servers section
  ///
  /// In en, this message translates to:
  /// **'Saved servers'**
  String get webdavSavedServers;

  /// Validation error
  ///
  /// In en, this message translates to:
  /// **'Host is required'**
  String get webdavHostRequired;

  /// Connection success message
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get webdavConnected;

  /// Connection error
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get webdavConnectionFailed;

  /// Save error
  ///
  /// In en, this message translates to:
  /// **'Save failed'**
  String get webdavSaveFailed;

  /// Edit dialog title
  ///
  /// In en, this message translates to:
  /// **'Edit server'**
  String get webdavEditServer;

  /// Server name field label
  ///
  /// In en, this message translates to:
  /// **'Server name'**
  String get webdavServerName;

  /// Protocol radio label
  ///
  /// In en, this message translates to:
  /// **'HTTP'**
  String get webdavHttp;

  /// Protocol radio label
  ///
  /// In en, this message translates to:
  /// **'HTTPS'**
  String get webdavHttps;

  /// Host field label
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get webdavHost;

  /// Port field label
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get webdavPort;

  /// Path field label
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get webdavPath;

  /// Username field label
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get webdavUsername;

  /// Password field label
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get webdavPassword;

  /// Password field hint on edit
  ///
  /// In en, this message translates to:
  /// **'Password (leave empty to keep)'**
  String get webdavPasswordKeep;

  /// Self-signed toggle label
  ///
  /// In en, this message translates to:
  /// **'Self-signed certificate'**
  String get webdavSelfSigned;

  /// Self-signed subtitle
  ///
  /// In en, this message translates to:
  /// **'Trust HTTPS servers without a CA certificate'**
  String get webdavSelfSignedDesc;

  /// HTTP warning
  ///
  /// In en, this message translates to:
  /// **'HTTP sends the password insecurely. Use HTTPS when connecting over the internet.'**
  String get webdavHttpInsecure;

  /// Bookmark success
  ///
  /// In en, this message translates to:
  /// **'Bookmarked {folder} to Home (WebDAV · {server})'**
  String webdavBookmarkAdded(String folder, String server);

  /// FTP browser title
  ///
  /// In en, this message translates to:
  /// **'FTP / SFTP'**
  String get ftpTitle;

  /// Server list button
  ///
  /// In en, this message translates to:
  /// **'Server list'**
  String get ftpServerList;

  /// Add FTP server button
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get ftpAddServer;

  /// Saved servers section
  ///
  /// In en, this message translates to:
  /// **'Saved servers'**
  String get ftpSavedServers;

  /// Protocol option
  ///
  /// In en, this message translates to:
  /// **'FTP'**
  String get ftpFtp;

  /// Protocol option
  ///
  /// In en, this message translates to:
  /// **'SFTP'**
  String get ftpSftp;

  /// Host field label
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get ftpHost;

  /// Port field label
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get ftpPort;

  /// Path field label
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get ftpPath;

  /// Username field label
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get ftpUsername;

  /// Password field label
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get ftpPassword;

  /// Password field hint on edit
  ///
  /// In en, this message translates to:
  /// **'Password (leave empty to keep)'**
  String get ftpPasswordKeep;

  /// Validation error
  ///
  /// In en, this message translates to:
  /// **'Host is required'**
  String get ftpHostRequired;

  /// Connection success
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get ftpConnected;

  /// Connection error
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get ftpConnectionFailed;

  /// Save error
  ///
  /// In en, this message translates to:
  /// **'Save failed'**
  String get ftpSaveFailed;

  /// Edit dialog title
  ///
  /// In en, this message translates to:
  /// **'Edit server'**
  String get ftpEditServer;

  /// FTP security warning
  ///
  /// In en, this message translates to:
  /// **'FTP sends credentials and data unencrypted. Use SFTP when connecting over the internet.'**
  String get ftpUnencryptedWarning;

  /// Jellyfin browser title
  ///
  /// In en, this message translates to:
  /// **'Jellyfin'**
  String get jellyfinTitle;

  /// Server list button
  ///
  /// In en, this message translates to:
  /// **'Server list'**
  String get jellyfinServerList;

  /// Network scan button
  ///
  /// In en, this message translates to:
  /// **'Scan network'**
  String get jellyfinScanNetwork;

  /// Add Jellyfin server button
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get jellyfinAddServer;

  /// Saved servers section
  ///
  /// In en, this message translates to:
  /// **'Saved servers'**
  String get jellyfinSavedServers;

  /// Discovered servers section
  ///
  /// In en, this message translates to:
  /// **'On this network'**
  String get jellyfinOnThisNetwork;

  /// Scan button
  ///
  /// In en, this message translates to:
  /// **'Scan local network'**
  String get jellyfinScanLocal;

  /// Add folder to library button
  ///
  /// In en, this message translates to:
  /// **'Add to library'**
  String get jellyfinAddToLibrary;

  /// Token expired error
  ///
  /// In en, this message translates to:
  /// **'Session expired'**
  String get jellyfinSessionExpired;

  /// Validation error
  ///
  /// In en, this message translates to:
  /// **'Server address is required'**
  String get jellyfinServerRequired;

  /// Login prompt
  ///
  /// In en, this message translates to:
  /// **'Enter a password to sign in.'**
  String get jellyfinEnterPassword;

  /// Edit dialog title
  ///
  /// In en, this message translates to:
  /// **'Edit server'**
  String get jellyfinEditServer;

  /// Server name field label
  ///
  /// In en, this message translates to:
  /// **'Server name'**
  String get jellyfinServerName;

  /// Server address field label
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get jellyfinServerAddress;

  /// Username field label
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get jellyfinUsername;

  /// Password field label
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get jellyfinPassword;

  /// Password field hint on edit
  ///
  /// In en, this message translates to:
  /// **'Password (leave empty to keep)'**
  String get jellyfinPasswordKeep;

  /// Self-signed toggle label
  ///
  /// In en, this message translates to:
  /// **'Self-signed certificate'**
  String get jellyfinSelfSigned;

  /// Self-signed subtitle
  ///
  /// In en, this message translates to:
  /// **'Trust HTTPS servers without a CA certificate'**
  String get jellyfinSelfSignedDesc;

  /// Username field hint
  ///
  /// In en, this message translates to:
  /// **'Enter your username.'**
  String get jellyfinEnterUsername;

  /// Password field hint
  ///
  /// In en, this message translates to:
  /// **'Enter your password.'**
  String get jellyfinEnterPasswordHint;

  /// Sign in button
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get jellyfinSignIn;

  /// DLNA browser title
  ///
  /// In en, this message translates to:
  /// **'DLNA'**
  String get upnpTitle;

  /// Discovery button
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get upnpDiscover;

  /// Discovery error
  ///
  /// In en, this message translates to:
  /// **'Discovery failed'**
  String get upnpDiscoverFailed;

  /// Browse error
  ///
  /// In en, this message translates to:
  /// **'Browse failed'**
  String get upnpBrowseFailed;

  /// Empty state
  ///
  /// In en, this message translates to:
  /// **'No DLNA servers found'**
  String get upnpNoServers;

  /// Retry discovery button
  ///
  /// In en, this message translates to:
  /// **'Discover again'**
  String get upnpDiscoverAgain;

  /// Diagnostics button
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get upnpDiagnostics;

  /// Download screen title
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get downloadTitle;

  /// Empty download list
  ///
  /// In en, this message translates to:
  /// **'No downloads yet'**
  String get downloadNoDownloads;

  /// Download in progress label
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get downloadDownloading;

  /// Download progress
  ///
  /// In en, this message translates to:
  /// **'Downloading: {title}'**
  String downloadDownloadingTitle(String title);

  /// Download complete label
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get downloadComplete;

  /// Download error
  ///
  /// In en, this message translates to:
  /// **'Download failed: {error}'**
  String downloadFailed(String error);

  /// Remove download dialog title
  ///
  /// In en, this message translates to:
  /// **'Remove download?'**
  String get downloadRemove;

  /// Download queued status
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get downloadQueued;

  /// Download cancelled status
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get downloadCancelled;

  /// Subtitle settings screen title
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get subtitleSettingsTitle;

  /// Size selector label
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get subtitleTextSize;

  /// Color selector label
  ///
  /// In en, this message translates to:
  /// **'Color'**
  String get subtitleColor;

  /// Background selector label
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get subtitleBackground;

  /// No background option
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get subtitleBackgroundNone;

  /// Semi-transparent background
  ///
  /// In en, this message translates to:
  /// **'Semi'**
  String get subtitleBackgroundSemi;

  /// Solid background
  ///
  /// In en, this message translates to:
  /// **'Solid'**
  String get subtitleBackgroundSolid;

  /// Outline toggle label
  ///
  /// In en, this message translates to:
  /// **'Black outline'**
  String get subtitleOutline;

  /// Outline subtitle
  ///
  /// In en, this message translates to:
  /// **'Shadow behind glyphs for readability'**
  String get subtitleOutlineDesc;

  /// Opacity slider label
  ///
  /// In en, this message translates to:
  /// **'Background opacity'**
  String get subtitleBgOpacity;

  /// Position slider label
  ///
  /// In en, this message translates to:
  /// **'Vertical position'**
  String get subtitlePosition;

  /// Position description
  ///
  /// In en, this message translates to:
  /// **'Move subtitle text up (higher) or down (lower).'**
  String get subtitlePositionDesc;

  /// Delay slider label
  ///
  /// In en, this message translates to:
  /// **'Delay'**
  String get subtitleDelay;

  /// Preview text
  ///
  /// In en, this message translates to:
  /// **'Sample subtitle line'**
  String get subtitleSample;

  /// Color option
  ///
  /// In en, this message translates to:
  /// **'White'**
  String get subtitleWhite;

  /// Color option
  ///
  /// In en, this message translates to:
  /// **'Yellow'**
  String get subtitleYellow;

  /// Color option
  ///
  /// In en, this message translates to:
  /// **'Cyan'**
  String get subtitleCyan;

  /// Color option
  ///
  /// In en, this message translates to:
  /// **'Warm'**
  String get subtitleWarm;

  /// File browser title
  ///
  /// In en, this message translates to:
  /// **'Browse files'**
  String get fileBrowseTitle;

  /// Files section label
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get fileBrowseFiles;

  /// Permission needed message
  ///
  /// In en, this message translates to:
  /// **'All files access is needed to browse your storage'**
  String get fileBrowseAccessNeeded;

  /// Grant permission button
  ///
  /// In en, this message translates to:
  /// **'Grant access'**
  String get fileBrowseGrant;

  /// Empty folder state
  ///
  /// In en, this message translates to:
  /// **'No videos or folders here'**
  String get fileBrowseNoVideos;

  /// Remove bookmark dialog title
  ///
  /// In en, this message translates to:
  /// **'Remove folder?'**
  String get fileBrowseRemoveFolder;

  /// Remove error
  ///
  /// In en, this message translates to:
  /// **'Could not remove the folder'**
  String get fileBrowseCouldNotRemove;

  /// Folder listing error
  ///
  /// In en, this message translates to:
  /// **'Could not list this folder'**
  String get folderCouldNotList;

  /// Episodes section header
  ///
  /// In en, this message translates to:
  /// **'Episodes'**
  String get folderEpisodes;

  /// Overview header
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get folderOverview;

  /// Cast section header
  ///
  /// In en, this message translates to:
  /// **'Cast'**
  String get folderCast;

  /// Search dialog title
  ///
  /// In en, this message translates to:
  /// **'Search OpenSubtitles'**
  String get opensubtitlesSearch;

  /// OpenSubtitles sign in title
  ///
  /// In en, this message translates to:
  /// **'Sign in to OpenSubtitles'**
  String get opensubtitlesSignIn;

  /// Language picker label
  ///
  /// In en, this message translates to:
  /// **'Download language'**
  String get opensubtitlesDownloadLang;

  /// Hash matching indicator
  ///
  /// In en, this message translates to:
  /// **'Hash match enabled'**
  String get opensubtitlesHashMatch;

  /// Hash computation loading
  ///
  /// In en, this message translates to:
  /// **'Computing file hash…'**
  String get opensubtitlesComputingHash;

  /// Search field hint
  ///
  /// In en, this message translates to:
  /// **'Movie / episode name'**
  String get opensubtitlesSearchHint;

  /// Empty search validation
  ///
  /// In en, this message translates to:
  /// **'Enter a search term'**
  String get opensubtitlesEnterSearch;

  /// No results state
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get opensubtitlesNoResults;

  /// Rate limit info
  ///
  /// In en, this message translates to:
  /// **'Free account = 20/day (anonymous = 5/day). Create at opensubtitles.com'**
  String get opensubtitlesFreeAccount;

  /// Rate limit reached
  ///
  /// In en, this message translates to:
  /// **'Sign in required for this download (daily anonymous limit reached)'**
  String get opensubtitlesSignInRequired;

  /// IO/network error
  ///
  /// In en, this message translates to:
  /// **'The video file could not be accessed. It may have been moved, deleted, or the network connection was lost.'**
  String get errorIo;

  /// Connection lost error
  ///
  /// In en, this message translates to:
  /// **'Connection interrupted while playing. The file may have been moved, the network may be unstable, or the server may have closed the connection.'**
  String get errorConnection;

  /// Server unreachable error
  ///
  /// In en, this message translates to:
  /// **'Could not reach the server. Check your network connection and make sure the server is running.'**
  String get errorServer;

  /// HTTP blocked error
  ///
  /// In en, this message translates to:
  /// **'Plain HTTP is blocked for this source. Use HTTPS if the server supports it.'**
  String get errorHttp;

  /// DV P5 not supported error
  ///
  /// In en, this message translates to:
  /// **'This device cannot decode Dolby Vision Profile 5. Play the HDR10 or SDR version of the file, or watch it on a Dolby Vision-capable device.'**
  String get errorDvP5;

  /// Decoder failure error
  ///
  /// In en, this message translates to:
  /// **'The video decoder failed while playing this file. It may be corrupted or use an unsupported encoding.'**
  String get errorDecoderFailed;

  /// Format unsupported error
  ///
  /// In en, this message translates to:
  /// **'This device cannot decode this video format. Common reasons include 10-bit HDR or an unsupported codec.'**
  String get errorFormatUnsupported;

  /// Decoder reclaimed error
  ///
  /// In en, this message translates to:
  /// **'The system reclaimed the video decoder. Reopening in software mode.'**
  String get errorResourcesReclaimed;

  /// Audio init error
  ///
  /// In en, this message translates to:
  /// **'Audio output could not be initialized. Check if another app is using the audio system, or try a different audio track.'**
  String get errorAudioInit;

  /// Container unsupported error
  ///
  /// In en, this message translates to:
  /// **'This file format is not supported. The container (e.g. .m2ts, .ts, .vob) may require a different decoder.'**
  String get errorContainerUnsupported;

  /// No external player error
  ///
  /// In en, this message translates to:
  /// **'No video player app found on this device'**
  String get errorNoVideoPlayer;

  /// GPLv3 license name
  ///
  /// In en, this message translates to:
  /// **'GNU General Public License v3.0'**
  String get licenseGplv3;

  /// Source code section header
  ///
  /// In en, this message translates to:
  /// **'Source code'**
  String get licenseSourceCode;

  /// Source code link label
  ///
  /// In en, this message translates to:
  /// **'GPLv3 source code'**
  String get licenseGplv3Source;

  /// Notice section label
  ///
  /// In en, this message translates to:
  /// **'GNU GPL v3.0 and third-party notices'**
  String get licenseNotice;

  /// Razorpay description
  ///
  /// In en, this message translates to:
  /// **'Pay via UPI, cards, or netbanking'**
  String get supportRazorpay;

  /// GitHub Sponsors description
  ///
  /// In en, this message translates to:
  /// **'Recurring support on GitHub'**
  String get supportGithub;

  /// Permission dialog title
  ///
  /// In en, this message translates to:
  /// **'Allow all files access?'**
  String get permissionsAllFiles;

  /// Permission dialog body
  ///
  /// In en, this message translates to:
  /// **'DreamPlayer needs All Files Access to browse your storage, play videos, and download files.'**
  String get permissionsAllFilesDesc;

  /// Decline permission button
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get permissionsNotNow;

  /// Open settings button
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get permissionsOpenSettings;

  /// Auto decoder mode
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get decoderAuto;

  /// Hardware decoder mode
  ///
  /// In en, this message translates to:
  /// **'Hardware'**
  String get decoderHardware;

  /// Software decoder mode
  ///
  /// In en, this message translates to:
  /// **'Software'**
  String get decoderSoftware;

  /// Auto engine option
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get engineAuto;

  /// Media3 engine option
  ///
  /// In en, this message translates to:
  /// **'Media3'**
  String get engineMedia3;

  /// libmpv engine option
  ///
  /// In en, this message translates to:
  /// **'libmpv'**
  String get engineMpv;

  /// Ask-every-time option
  ///
  /// In en, this message translates to:
  /// **'Ask every time'**
  String get engineAsk;

  /// Fit to screen
  ///
  /// In en, this message translates to:
  /// **'Fit'**
  String get fitModeFit;

  /// Fill screen
  ///
  /// In en, this message translates to:
  /// **'Fullscreen'**
  String get fitModeFullscreen;

  /// Crop to fill
  ///
  /// In en, this message translates to:
  /// **'Crop to screen'**
  String get fitModeCrop;

  /// Stretch to fill
  ///
  /// In en, this message translates to:
  /// **'Stretch to screen'**
  String get fitModeStretch;

  /// Repeat one mode
  ///
  /// In en, this message translates to:
  /// **'Repeat one'**
  String get playbackRepeatOne;

  /// Repeat all mode
  ///
  /// In en, this message translates to:
  /// **'Repeat all'**
  String get playbackRepeatAll;

  /// SMB source badge
  ///
  /// In en, this message translates to:
  /// **'SMB'**
  String get librarySourceSmb;

  /// WebDAV source badge
  ///
  /// In en, this message translates to:
  /// **'WebDAV'**
  String get librarySourceWebdav;

  /// FTP source badge
  ///
  /// In en, this message translates to:
  /// **'FTP'**
  String get librarySourceFtp;

  /// DLNA source badge
  ///
  /// In en, this message translates to:
  /// **'DLNA'**
  String get librarySourceDlna;

  /// Jellyfin source badge
  ///
  /// In en, this message translates to:
  /// **'Jellyfin'**
  String get librarySourceJellyfin;

  /// HDR10 badge
  ///
  /// In en, this message translates to:
  /// **'HDR10'**
  String get badgeHdr10;

  /// HLG badge
  ///
  /// In en, this message translates to:
  /// **'HLG'**
  String get badgeHlg;

  /// SDR badge
  ///
  /// In en, this message translates to:
  /// **'SDR'**
  String get badgeSdr;

  /// Dolby Vision badge
  ///
  /// In en, this message translates to:
  /// **'Dolby Vision'**
  String get badgeDolbyVision;

  /// Spatial audio badge
  ///
  /// In en, this message translates to:
  /// **'Spatial'**
  String get badgeSpatial;

  /// Transcoding badge
  ///
  /// In en, this message translates to:
  /// **'Transcoding'**
  String get badgeTranscoding;

  /// SDR MPV badge
  ///
  /// In en, this message translates to:
  /// **'SDR (MPV)'**
  String get badgeSdrMpv;

  /// 5 minute timer
  ///
  /// In en, this message translates to:
  /// **'5 min'**
  String get sleep5min;

  /// 10 minute timer
  ///
  /// In en, this message translates to:
  /// **'10 min'**
  String get sleep10min;

  /// 15 minute timer
  ///
  /// In en, this message translates to:
  /// **'15 min'**
  String get sleep15min;

  /// 30 minute timer
  ///
  /// In en, this message translates to:
  /// **'30 min'**
  String get sleep30min;

  /// 60 minute timer
  ///
  /// In en, this message translates to:
  /// **'60 min'**
  String get sleep60min;

  /// End-of-video timer
  ///
  /// In en, this message translates to:
  /// **'End of current video'**
  String get sleepEndOfVideo;

  /// Timer expired message
  ///
  /// In en, this message translates to:
  /// **'Sleep timer finished — playback paused'**
  String get sleepFinished;

  /// Volume off state
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get volumeOff;

  /// TMDB hint dialog title
  ///
  /// In en, this message translates to:
  /// **'Enable movie details?'**
  String get tmdbHintEnable;

  /// TMDB hint dialog body
  ///
  /// In en, this message translates to:
  /// **'DreamPlayer can fetch movie posters, ratings, cast, and other details from The Movie Database (TMDB) for free.'**
  String get tmdbHintDesc;

  /// TMDB key instruction link
  ///
  /// In en, this message translates to:
  /// **'Get a free TMDB API key'**
  String get tmdbGetKey;

  /// Open settings button in TMDB hint
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get tmdbOpenSettings;

  /// Bookmark success message
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" added to your library'**
  String bookmarkedAdded(String name);

  /// Continue-watching removal message
  ///
  /// In en, this message translates to:
  /// **'\"{title}\" will no longer appear here.'**
  String removedFromContinue(String title);

  /// Server removed message
  ///
  /// In en, this message translates to:
  /// **'Removed {server}'**
  String folderRemoved(String server);

  /// Cache cleared message
  ///
  /// In en, this message translates to:
  /// **'Cache cleared'**
  String get cacheCleared;

  /// Cross-platform note
  ///
  /// In en, this message translates to:
  /// **'Live on iOS · reopens at same position on Android'**
  String get liveOnIos;

  /// Decoder switch note
  ///
  /// In en, this message translates to:
  /// **'Reopens at same position to switch decoder.'**
  String get reopensSamePosition;

  /// Hash matching indicator
  ///
  /// In en, this message translates to:
  /// **'Hash match enabled'**
  String get hashMatchEnabled;

  /// Video unavailable message
  ///
  /// In en, this message translates to:
  /// **'This video isn\'t available to play.'**
  String get videoNotAvailable;

  /// Generic error display
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String genericError(String error);

  /// Settings subtitle encoding title
  ///
  /// In en, this message translates to:
  /// **'Subtitle encoding'**
  String get settingsSubtitleEncoding;

  /// Settings language section title
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// System default language option
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get settingsSystemDefault;

  /// OpenSubtitles account hint text
  ///
  /// In en, this message translates to:
  /// **'Free account = 20/day (anonymous = 5/day). Create at opensubtitles.com'**
  String get settingsOpensubAccountHint;

  /// Sign in button
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get settingsSignIn;

  /// Remove button
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get settingsRemove;

  /// Clear cache confirmation title
  ///
  /// In en, this message translates to:
  /// **'Clear cache?'**
  String get settingsClearCacheConfirm;

  /// Could not open link error
  ///
  /// In en, this message translates to:
  /// **'Could not open this link'**
  String get settingsCouldNotOpenLink;

  /// Badge options description
  ///
  /// In en, this message translates to:
  /// **'Choose which chips to show'**
  String get settingsBadgeOptionsDesc;

  /// Decoder takes effect hint
  ///
  /// In en, this message translates to:
  /// **'Takes effect on next video'**
  String get settingsTakesEffectNextVideo;

  /// TMDB API key setting title
  ///
  /// In en, this message translates to:
  /// **'TMDB API key'**
  String get settingsTmdbApiKey;

  /// OpenSubtitles setting title
  ///
  /// In en, this message translates to:
  /// **'OpenSubtitles'**
  String get settingsOpensubtitles;

  /// Auto download subtitles description
  ///
  /// In en, this message translates to:
  /// **'Download best match when no subtitles found'**
  String get settingsAutoDownloadSubs;

  /// SIMKL sign out description
  ///
  /// In en, this message translates to:
  /// **'Sign out and stop syncing'**
  String get settingsSimklSignOut;

  /// SIMKL sync description
  ///
  /// In en, this message translates to:
  /// **'Sync watched history with simkl.com (free unlimited)'**
  String get settingsSimklSyncDesc;

  /// GNU GPL license notice
  ///
  /// In en, this message translates to:
  /// **'GNU GPL v3.0 and third-party notices'**
  String get settingsGnuGpl;

  /// SIMKL sync count snackbar
  ///
  /// In en, this message translates to:
  /// **'Synced {count} item(s) to SIMKL'**
  String settingsSyncedCount(int count);

  /// Connect SIMKL title
  ///
  /// In en, this message translates to:
  /// **'Connect SIMKL'**
  String get settingsConnectSimkl;

  /// SIMKL pairing instructions
  ///
  /// In en, this message translates to:
  /// **'Go to the address below and enter this code:'**
  String get settingsSimklPairing;

  /// OpenSubtitles anonymous usage hint
  ///
  /// In en, this message translates to:
  /// **'Anonymous = 5/day, free account = 20/day'**
  String get opensubtitlesAnonymousHint;

  /// Downloading subtitle indicator
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get opensubtitlesDownloading;

  /// Empty folder message
  ///
  /// In en, this message translates to:
  /// **'No videos or folders here'**
  String get folderNoVideosHere;

  /// SIMKL not configured message
  ///
  /// In en, this message translates to:
  /// **'SIMKL not configured'**
  String get folderSimklNotConfigured;

  /// SIMKL sign in required
  ///
  /// In en, this message translates to:
  /// **'Sign in to SIMKL first'**
  String get folderSimklSignInFirst;

  /// SIMKL sync failed error
  ///
  /// In en, this message translates to:
  /// **'SIMKL sync failed: {error}'**
  String folderSimklSyncFailed(String error);

  /// No SMB shares found message
  ///
  /// In en, this message translates to:
  /// **'No shares found. Check your NAS share settings.'**
  String get folderSmbNoShares;

  /// Download snackbar title
  ///
  /// In en, this message translates to:
  /// **'Downloading: {title}'**
  String playerDownloadingTitle(String title);

  /// Download failed error
  ///
  /// In en, this message translates to:
  /// **'Download failed: {error}'**
  String playerDownloadFailed(String error);

  /// Video not supported by built-in player
  ///
  /// In en, this message translates to:
  /// **'This video isn\'t supported by the built-in player, so the fallback player is being used.'**
  String get playerVideoNotSupported;

  /// Sleep timer finished message
  ///
  /// In en, this message translates to:
  /// **'Sleep timer finished — playback paused'**
  String get playerSleepTimerFinished;

  /// Downloaded status label
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get playerDownloaded;

  /// Auto-fetched file notification
  ///
  /// In en, this message translates to:
  /// **'Auto-fetched: {fileName}'**
  String playerAutoFetched(String fileName);

  /// Picture-in-picture setting
  ///
  /// In en, this message translates to:
  /// **'Picture-in-picture'**
  String get playerPictureInPicture;

  /// No SMB shares found on home
  ///
  /// In en, this message translates to:
  /// **'No shares found. Check your NAS share settings.'**
  String get homeSmbNoShares;

  /// Retry button on error surface
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get errorRetry;

  /// Try with MPV button on error surface
  ///
  /// In en, this message translates to:
  /// **'Try with MPV'**
  String get errorTryMpv;

  /// Open in external player button
  ///
  /// In en, this message translates to:
  /// **'Open in external player'**
  String get errorOpenExternal;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'es', 'ru', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en': return AppLocalizationsEn();
    case 'es': return AppLocalizationsEs();
    case 'ru': return AppLocalizationsRu();
    case 'zh': return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
