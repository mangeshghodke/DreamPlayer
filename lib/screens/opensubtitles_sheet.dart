import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/context_text.dart';
import '../services/downloaded_subtitles_store.dart';
import '../services/opensubtitles_client.dart';
import '../services/subtitle_languages.dart';
import '../services/subtitle_prefs.dart';

/// Bottom sheet for OpenSubtitles search & download (anonymous 5/day, login 20/day).
class OpensubtitlesSheet extends StatefulWidget {
  const OpensubtitlesSheet({
    super.key,
    required this.initialQuery,
    this.filePath,
    this.resumeKey,
  });

  /// Prefilled search term (video title / parsed name).
  final String initialQuery;

  /// Local file path for hash-based search (optional).
  final String? filePath;

  /// Resume key for persisting downloaded subtitle (store top section).
  final String? resumeKey;

  @override
  State<OpensubtitlesSheet> createState() => _OpensubtitlesSheetState();
}

class _OpensubtitlesSheetState extends State<OpensubtitlesSheet> {
  late final TextEditingController _queryCtrl;
  String _novaCode = 'eng';
  bool _searching = false;
  bool _downloading = false;
  String? _error;
  List<OpensubtitlesResult> _results = const [];
  String? _hash;
  bool _hashSearching = false;

  @override
  void initState() {
    super.initState();
    _queryCtrl = TextEditingController(text: widget.initialQuery);
    _loadDownloadLang();
    _maybeHash();
  }

  Future<void> _loadDownloadLang() async {
    try {
      final code = await SubtitlePrefs.loadDownloadLanguage();
      if (mounted) setState(() => _novaCode = code);
    } catch (_) {}
  }

  Future<void> _maybeHash() async {
    final p = widget.filePath;
    if (p == null || p.isEmpty) return;
    setState(() => _hashSearching = true);
    final h = await opensubtitlesHashForFile(p);
    if (mounted)
      setState(() {
        _hash = h;
        _hashSearching = false;
      });
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLanguage() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('Download language', '下载语言')),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: RadioGroup<String>(
            groupValue: _novaCode,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: ListView.builder(
              itemCount: subtitleLanguages.length,
              itemBuilder: (_, i) {
                final l = subtitleLanguages[i];
                if (l.novaCode == 'system') return const SizedBox.shrink();
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
    if (picked != null && mounted) setState(() => _novaCode = picked);
  }

  Future<void> _search() async {
    final q = _queryCtrl.text.trim();
    final langs = openSubsCodeForNovaCode(_novaCode);
    if (q.isEmpty && _hash == null) {
      setState(() => _error = context.tr('Enter a search term', '请输入搜索内容'));
      return;
    }
    if (!OpensubtitlesClient.instance.hasApiKey) {
      setState(
        () => _error = context.tr(
          'OpenSubtitles is not configured',
          '尚未配置 OpenSubtitles',
        ),
      );
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
      _results = const [];
    });
    try {
      final res = await OpensubtitlesClient.instance.search(
        query: q,
        languages: langs,
        movieHash: _hash,
      );
      if (!mounted) return;
      setState(() {
        _results = res;
        _searching = false;
        if (res.isEmpty) _error = context.tr('No results', '没有找到结果');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = e.toString();
      });
    }
  }

  Future<String?> _downloadToPersistent(
    OpensubtitlesResult r, {
    required String fileName,
    required List<int> bytes,
  }) async {
    // OpenSubtitles often returns a meaningless upload id (`1324.srt`) as the
    // file name — surface the real name derived from the video title + lang.
    final derived = meaningfulSubtitleFileName(
      apiFileName: fileName,
      language: r.language,
      videoTitle: widget.initialQuery,
    );
    final rk = widget.resumeKey;
    if (rk != null && rk.isNotEmpty) {
      final entry = await DownloadedSubtitlesStore.saveForVideo(
        resumeKey: rk,
        tempPath: await _writeTemp(derived, bytes),
        fileName: derived,
        language: r.language,
      );
      return entry.path;
    }
    return _writeTemp(derived, bytes);
  }

  Future<String> _writeTemp(String fileName, List<int> bytes) async {
    final dir = await getTemporaryDirectory();
    final subDir = Directory('${dir.path}/opensubs');
    if (!await subDir.exists()) await subDir.create(recursive: true);
    final safeName = fileName.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final file = File('${subDir.path}/$safeName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> _download(OpensubtitlesResult r) async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      final info = await OpensubtitlesClient.instance.requestDownload(r.fileId);
      final bytes = await OpensubtitlesClient.instance.fetchBytes(info.link);
      final persisted = await _downloadToPersistent(
        r,
        fileName: info.fileName,
        bytes: bytes,
      );
      if (!mounted) return;
      Navigator.of(context).pop(persisted);
    } catch (e) {
      final msg = e.toString();
      final isQuota =
          msg.toLowerCase().contains('limit') ||
          msg.toLowerCase().contains('quota') ||
          msg.contains('401');
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = msg;
      });
      if (isQuota) {
        final loggedIn = await _showLoginDialog();
        if (loggedIn == true && mounted) {
          try {
            setState(() => _downloading = true);
            final info = await OpensubtitlesClient.instance.requestDownload(
              r.fileId,
            );
            final bytes = await OpensubtitlesClient.instance.fetchBytes(
              info.link,
            );
            final persisted = await _downloadToPersistent(
              r,
              fileName: info.fileName,
              bytes: bytes,
            );
            if (!mounted) return;
            Navigator.of(context).pop(persisted);
          } catch (e2) {
            if (mounted)
              setState(() {
                _downloading = false;
                _error = e2.toString();
              });
          }
        }
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<bool?> _showLoginDialog() async {
    final uCtrl = TextEditingController();
    final pCtrl = TextEditingController();
    String? err;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2E),
          title: Text(
            context.tr('Sign in to OpenSubtitles', '登录 OpenSubtitles'),
            style: const TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: uCtrl,
                decoration: InputDecoration(
                  labelText: context.tr('Username', '用户名'),
                  labelStyle: const TextStyle(color: Colors.white70),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: pCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.tr('Password', '密码'),
                  labelStyle: const TextStyle(color: Colors.white70),
                ),
                style: const TextStyle(color: Colors.white),
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
                  'Anonymous = 5/day, free account = 20/day',
                  '匿名用户每天 5 次，免费账户每天 20 次',
                ),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
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
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  context.tr('Search OpenSubtitles', '搜索 OpenSubtitles'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _queryCtrl,
                        decoration: InputDecoration(
                          hintText: context.tr(
                            'Movie / episode name',
                            '电影或剧集名称',
                          ),
                          hintStyle: const TextStyle(color: Colors.white38),
                        ),
                        style: const TextStyle(color: Colors.white),
                        onSubmitted: (_) => _search(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: _pickLanguage,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white24),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              displayNameForNovaCode(_novaCode),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.arrow_drop_down,
                              color: Colors.white70,
                              size: 16,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _searching ? null : _search,
                      child: _searching
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(context.tr('Search', '搜索')),
                    ),
                  ],
                ),
              ),
              if (_hash != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    context.tr('Hash match enabled', '已启用文件哈希匹配'),
                    style: TextStyle(
                      color: Colors.green.shade300,
                      fontSize: 11,
                    ),
                  ),
                ),
              if (_hashSearching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    context.tr('Computing file hash…', '正在计算文件哈希…'),
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              const Divider(color: Colors.white12, height: 16),
              if (_downloading)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        context.tr('Downloading…', '正在下载…'),
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (ctx, i) {
                    final r = _results[i];
                    final lang = r.language.isEmpty
                        ? '?'
                        : r.language.toUpperCase();
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.white12,
                        child: Text(
                          lang,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      title: Text(
                        r.fileName.isEmpty
                            ? (r.release ??
                                  '${context.tr('Subtitle', '字幕')} ${r.fileId}')
                            : r.fileName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${r.downloads} ${context.tr('downloads', '次下载')} · ★ ${r.ratings.toStringAsFixed(1)}${r.release != null ? ' · ${r.release}' : ''}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: _downloading ? null : () => _download(r),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
