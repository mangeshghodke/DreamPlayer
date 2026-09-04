// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => 'DreamPlayer';

  @override
  String get library => '媒体库';

  @override
  String get settings => '设置';

  @override
  String get appearance => '外观';

  @override
  String get language => '应用语言';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageChinese => '简体中文';

  @override
  String get theme => '主题';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get remoteServers => '远程服务器';

  @override
  String get noRemoteServers => '暂无已保存的远程服务器';

  @override
  String get configured => '已配置';

  @override
  String get signedIn => '已登录';

  @override
  String get signInRequired => '需要登录';

  @override
  String get guest => '访客';

  @override
  String get noLogin => '无需登录';

  @override
  String get selfSignedAllowed => '允许自签名证书';

  @override
  String get yourLibrary => '我的媒体库';

  @override
  String get continueWatching => '继续观看';

  @override
  String get nothingYet => '这里还没有内容';

  @override
  String get emptyLibraryHint => '播放过的视频会显示在这里。';

  @override
  String get noFoldersPhone => '还没有文件夹，点击 + 添加。';

  @override
  String get noFoldersTv => '还没有文件夹，请使用上方按钮添加。';

  @override
  String get addSource => '添加来源';

  @override
  String get addFolderToLibrary => '添加文件夹到媒体库';

  @override
  String get folderExamples => '电视剧文件夹、电影文件夹等';

  @override
  String get internalStorage => '内部存储';

  @override
  String get browseDeviceFiles => '浏览此设备上的文件';

  @override
  String get networkSources => '网络来源';

  @override
  String get networkSourcesSubtitle => '此网络中的服务器';

  @override
  String get smbNas => 'SMB / NAS';

  @override
  String get smbAndroidSubtitle => '局域网中的 SMB 共享';

  @override
  String get smbIosSubtitle => '通过“文件”App 访问 SMB';

  @override
  String get addWebDavServer => '添加 WebDAV 服务器';

  @override
  String get ftpServerSubtitle => 'FTP 或 SFTP 文件服务器';

  @override
  String get jellyfinServerSubtitle => 'Jellyfin / Emby 媒体服务器';

  @override
  String get dlnaSubtitle => '此网络中的 UPnP / DLNA 服务器';

  @override
  String get playUrl => '播放网址';

  @override
  String get playUrlSubtitle => '播放视频直链';

  @override
  String get videoUrl => '视频网址';

  @override
  String get cancel => '取消';

  @override
  String get play => '播放';

  @override
  String get invalidHttpUrl => '请输入有效的 http(s) 网址';

  @override
  String get pressBackAgain => '再按一次返回键退出';

  @override
  String get up => '返回上一级';

  @override
  String get serverList => '服务器列表';

  @override
  String get refresh => '刷新';

  @override
  String get addServer => '添加服务器';

  @override
  String get savedServers => '已保存的服务器';

  @override
  String get retry => '重试';

  @override
  String errorMessage(String message) {
    return '错误：$message';
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
  String get support => '支持';

  @override
  String get storage => '存储';

  @override
  String get player => '播放器';

  @override
  String get about => '关于';

  @override
  String get faq => '常见问题';

  @override
  String get selectLanguage => '选择应用语言';

  @override
  String get selectTheme => '选择主题';

  @override
  String get nothingHere => '这里没有内容';

  @override
  String get bookmarkFolder => '将此文件夹收藏到首页';

  @override
  String bookmarkAdded(String folder, String protocol, String server) {
    return '已将 $folder 收藏到首页（$protocol · $server）';
  }

  @override
  String removedServer(String server) {
    return '已移除 $server';
  }

  @override
  String get edit => '编辑';

  @override
  String get delete => '删除';

  @override
  String get save => '保存';

  @override
  String get test => '测试';

  @override
  String get optional => '可选';

  @override
  String get serverName => '服务器名称';

  @override
  String get name => '名称';

  @override
  String get host => '主机';

  @override
  String get port => '端口';

  @override
  String get path => '路径';

  @override
  String get username => '用户名';

  @override
  String get password => '密码';

  @override
  String get domain => '域';

  @override
  String get networkShares => '网络共享';

  @override
  String get scanNetwork => '扫描网络';

  @override
  String get scanningNetwork => '正在扫描网络…';

  @override
  String get selfSignedCertificate => '自签名证书';

  @override
  String get addToLibrary => '添加到媒体库';

  @override
  String signedInTo(String server) {
    return '已登录到 $server';
  }

  @override
  String addedToLibrary(String name) {
    return '已将“$name”添加到媒体库';
  }

  @override
  String get signIn => '登录';

  @override
  String get editServer => '编辑服务器';

  @override
  String get serverAddress => '服务器地址';

  @override
  String get guestNoCredentials => '访客——无需用户名和密码';

  @override
  String get detectedOnNetwork => '在当前网络中发现';

  @override
  String get onThisNetwork => '当前网络';

  @override
  String get scanLocalNetwork => '扫描局域网';

  @override
  String get scanning => '正在扫描…';

  @override
  String signedInAs(String username) {
    return '已以 $username 登录';
  }

  @override
  String get notSignedIn => '未登录';

  @override
  String get clearCache => '清理缓存';

  @override
  String get audioPassthrough => '音频直通';

  @override
  String get swipeGestures => '滑动手势';

  @override
  String get pictureInPicture => '画中画';

  @override
  String get autoPlayNextEpisode => '自动播放下一集';

  @override
  String get onScreenBadges => '屏幕格式标记';

  @override
  String get badgeOptions => '标记选项';

  @override
  String get volumeBoost => '音量增强';

  @override
  String get nightMode => '夜间模式';

  @override
  String get videoDecoder => '视频解码器';

  @override
  String get metadata => '元数据';

  @override
  String get tmdbApiKey => 'TMDB API 密钥';

  @override
  String get subtitles => '字幕';

  @override
  String get subtitleReadingLanguage => '字幕阅读语言';

  @override
  String get subtitleDownloadLanguage => '字幕下载语言';

  @override
  String get subtitleEncoding => '字幕编码';

  @override
  String get autoFetchSubtitles => '自动获取字幕';

  @override
  String get engine => '播放引擎';

  @override
  String get version => '版本';

  @override
  String get openSourceLicenses => '开源许可证';

  @override
  String get noSharesFound => '未找到共享。请检查 NAS 的共享设置，并确认共享在网络中可见。';
}
