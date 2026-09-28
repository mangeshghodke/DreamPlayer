import 'package:flutter/material.dart';

import '../services/metadata_search.dart';
import '../services/tmdb_client.dart';
import 'cached_image.dart';

/// Poster picker for a manual group — query + Movie/TV toggle, results
/// list, tap a result to pick it. Returns the picked [TmdMeta] or null
/// (skip/cancel) so the group falls back to any member's cached meta.
/// Shared by the group-creation flow (home screen) and the group detail
/// screen's Fix match.
///
/// Search runs across every configured metadata provider (TMDB, TheTVDB) and
/// shows one merged, de-duplicated result list — no provider picker.
class GroupPosterDialog extends StatefulWidget {
  const GroupPosterDialog({super.key, required this.initialQuery});

  final String initialQuery;

  @override
  State<GroupPosterDialog> createState() => _GroupPosterDialogState();
}

class _GroupPosterDialogState extends State<GroupPosterDialog> {
  final _controller = TextEditingController();
  final _search = MetadataSearch();
  List<TmdMovie>? _results;
  bool _searching = false;
  int _searchGeneration = 0;
  String? _error;
  bool _noKey = false;
  TmdKind _kind = TmdKind.movie;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery;
    if (_controller.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runSearch();
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _controller.text.trim();
    final generation = ++_searchGeneration;
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _results = null;
      _error = null;
      _noKey = false;
    });
    try {
      if (!await _search.hasAnyProvider) {
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _searching = false;
          _results = null;
          _noKey = true;
        });
        return;
      }
      final results = await _search.search(query, kind: _kind);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searching = false;
        _results = results.isEmpty ? null : results;
        if (results.isEmpty) _error = 'No results for "$query"';
      });
    } catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searching = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose poster'),
      content: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Search…',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _runSearch,
                ),
              ),
              onSubmitted: (_) => _runSearch(),
            ),
            const SizedBox(height: 8),
            SegmentedButton<TmdKind>(
              segments: const [
                ButtonSegment(value: TmdKind.movie, label: Text('Movie')),
                ButtonSegment(value: TmdKind.tv, label: Text('TV')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) {
                setState(() => _kind = s.first);
                _runSearch();
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _buildResults(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Skip'),
        ),
      ],
    );
  }

  Widget _buildResults() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_noKey) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Add a TMDB or TheTVDB API key in Settings → Metadata to search.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_results == null) {
      return const Center(child: Text('Search to pick a poster'));
    }
    return ListView.separated(
      itemCount: _results!.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final m = _results![index];
        final poster = m.posterUrl();
        return ListTile(
          leading: poster != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CachedImage(
                    poster,
                    width: 40,
                    height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                )
              : const SizedBox(width: 40, height: 60),
          title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [if (m.year != null) '${m.year}'].join(' · '),
          ),
          trailing: m.kind == TmdKind.tv
              ? const Text('TV',
                  style: TextStyle(fontSize: 11, color: Colors.purple))
              : const Text('Movie',
                  style: TextStyle(fontSize: 11, color: Colors.blue)),
          onTap: () {
            Navigator.of(context).pop(TmdMeta(
              movie: m,
              manual: true,
            ));
          },
        );
      },
    );
  }
}
