// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'DreamPlayer';

  @override
  String get library => 'Library';

  @override
  String get settings => 'Settings';

  @override
  String get appearance => 'Appearance';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'Follow system';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageChinese => 'Simplified Chinese';

  @override
  String get theme => 'Theme';

  @override
  String get themeSystem => 'Follow system';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get remoteServers => 'Remote servers';

  @override
  String get noRemoteServers => 'No saved remote servers';

  @override
  String get configured => 'Configured';

  @override
  String get signedIn => 'Signed in';

  @override
  String get signInRequired => 'Sign-in required';

  @override
  String get guest => 'Guest';

  @override
  String get noLogin => 'No login';

  @override
  String get selfSignedAllowed => 'self-signed allowed';

  @override
  String get yourLibrary => 'Your library';

  @override
  String get continueWatching => 'Continue watching';

  @override
  String get nothingYet => 'Nothing yet';

  @override
  String get emptyLibraryHint => 'Videos you play will appear here.';

  @override
  String get noFoldersPhone => 'No folders yet. Tap + to add one.';

  @override
  String get noFoldersTv => 'No folders yet. Use the buttons above to add one.';

  @override
  String get addSource => 'Add a source';

  @override
  String get addFolderToLibrary => 'Add folder to library';

  @override
  String get folderExamples => 'A TV-show folder, a movie folder…';

  @override
  String get internalStorage => 'Internal storage';

  @override
  String get browseDeviceFiles => 'Browse files on this device';

  @override
  String get networkSources => 'Network sources';

  @override
  String get networkSourcesSubtitle => 'Servers on this network';

  @override
  String get smbNas => 'SMB / NAS';

  @override
  String get smbAndroidSubtitle => 'SMB shares on the local network';

  @override
  String get smbIosSubtitle => 'SMB via the Files app';

  @override
  String get addWebDavServer => 'Add a WebDAV server';

  @override
  String get ftpServerSubtitle => 'FTP or SFTP file server';

  @override
  String get jellyfinServerSubtitle => 'Jellyfin / Emby media server';

  @override
  String get dlnaSubtitle => 'UPnP / DLNA servers on this network';

  @override
  String get playUrl => 'Play URL';

  @override
  String get playUrlSubtitle => 'Stream a direct video link';

  @override
  String get videoUrl => 'Video URL';

  @override
  String get cancel => 'Cancel';

  @override
  String get play => 'Play';

  @override
  String get invalidHttpUrl => 'Enter a valid http(s) URL';

  @override
  String get pressBackAgain => 'Press back again to exit';

  @override
  String get up => 'Up';

  @override
  String get serverList => 'Server list';

  @override
  String get refresh => 'Refresh';

  @override
  String get addServer => 'Add server';

  @override
  String get savedServers => 'Saved servers';

  @override
  String get retry => 'Retry';

  @override
  String errorMessage(String message) {
    return 'Error: $message';
  }

  @override
  String get webDav => 'WebDAV';

  @override
  String get ftpSftp => 'FTP / SFTP';

  @override
  String get jellyfin => 'Jellyfin';

  @override
  String get dlna => 'DLNA';

  @override
  String get support => 'Support';

  @override
  String get storage => 'Storage';

  @override
  String get player => 'Player';

  @override
  String get about => 'About';

  @override
  String get faq => 'FAQ';

  @override
  String get selectLanguage => 'Select language';

  @override
  String get selectTheme => 'Select theme';

  @override
  String get nothingHere => 'Nothing here';

  @override
  String get bookmarkFolder => 'Bookmark this folder to Home';

  @override
  String bookmarkAdded(String folder, String protocol, String server) {
    return 'Bookmarked $folder to Home ($protocol · $server)';
  }

  @override
  String removedServer(String server) {
    return 'Removed $server';
  }

  @override
  String get edit => 'Edit';

  @override
  String get delete => 'Delete';

  @override
  String get save => 'Save';

  @override
  String get test => 'Test';

  @override
  String get optional => 'optional';

  @override
  String get serverName => 'Server name';

  @override
  String get name => 'Name';

  @override
  String get host => 'Host';

  @override
  String get port => 'Port';

  @override
  String get path => 'Path';

  @override
  String get username => 'Username';

  @override
  String get password => 'Password';

  @override
  String get domain => 'Domain';

  @override
  String get networkShares => 'Network shares';

  @override
  String get scanNetwork => 'Scan network';

  @override
  String get scanningNetwork => 'Scanning your network…';

  @override
  String get selfSignedCertificate => 'Self-signed certificate';

  @override
  String get addToLibrary => 'Add to library';

  @override
  String signedInTo(String server) {
    return 'Signed in to $server';
  }

  @override
  String addedToLibrary(String name) {
    return '\"$name\" added to your library';
  }

  @override
  String get signIn => 'Sign in';

  @override
  String get editServer => 'Edit server';

  @override
  String get serverAddress => 'Server address';

  @override
  String get guestNoCredentials => 'Guest — no username/password';

  @override
  String get detectedOnNetwork => 'Detected on this network';

  @override
  String get onThisNetwork => 'On this network';

  @override
  String get scanLocalNetwork => 'Scan local network';

  @override
  String get scanning => 'Scanning…';

  @override
  String signedInAs(String username) {
    return 'Signed in as $username';
  }

  @override
  String get notSignedIn => 'Not signed in';

  @override
  String get clearCache => 'Clear cache';

  @override
  String get audioPassthrough => 'Audio passthrough';

  @override
  String get swipeGestures => 'Swipe gestures';

  @override
  String get pictureInPicture => 'Picture-in-picture';

  @override
  String get autoPlayNextEpisode => 'Auto-play next episode';

  @override
  String get onScreenBadges => 'On-screen badges';

  @override
  String get badgeOptions => 'Badge options';

  @override
  String get volumeBoost => 'Volume Boost';

  @override
  String get nightMode => 'Night Mode';

  @override
  String get videoDecoder => 'Video decoder';

  @override
  String get metadata => 'Metadata';

  @override
  String get tmdbApiKey => 'TMDB API key';

  @override
  String get subtitles => 'Subtitles';

  @override
  String get subtitleReadingLanguage => 'Subtitle reading language';

  @override
  String get subtitleDownloadLanguage => 'Subtitle download language';

  @override
  String get subtitleEncoding => 'Subtitle encoding';

  @override
  String get autoFetchSubtitles => 'Auto-fetch subtitles';

  @override
  String get engine => 'Engine';

  @override
  String get version => 'Version';

  @override
  String get openSourceLicenses => 'Open-source licenses';

  @override
  String get noSharesFound =>
      'No shares found. Check your NAS share settings and make sure shares are visible to the network.';
}
