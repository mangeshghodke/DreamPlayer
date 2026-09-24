import 'package:flutter/material.dart';

import '../services/tmdb_client.dart';
import '../services/the_tvdb_client.dart';
import 'cached_image.dart';

/// TMDB poster picker for a manual group — query + Movie/TV toggle, results
/// list, tap a result to pick it. Returns the picked [TmdMeta] or null
/// (skip/cancel) so the group falls back to any member's cached meta.
/// Shared by the group-creation flow (home screen) and the group detail
/// screen's Fix match.
class GroupPosterDialog extends StatefulWidget {
  const GroupPosterDialog({super.key, required this.initialQuery});

  final String initialQuery;

  @override
  State<GroupPosterDialog> createState() => _GroupPosterDialogState();
}

class _GroupPosterDialogState extends State<GroupPosterDialog> {
  final _controller = TextEditingController();
  final _api = TmdApi();
  final _theTvdb = TheTvdbClient();
  List<TmdMovie>? _results;
  bool _searching = false;
  int _searchGeneration = 0;
  String? _error;
  TmdKind _kind = TmdKind.movie;
  MetadataProvider _provider = MetadataProvider.tmdb;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery;
    if (_controller.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  @override
  void dispose() {
    _theTvdb.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    final generation = ++_searchGeneration;
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _results = null;
      _error = null;
    });
    try {
      // The Movie/TV tab is honored: only the SELECTED kind is searched.
      // The other kind fills in only when the primary returns empty
      // (kind-first fallback), so the tab is never just a reorder.
      var results = _provider == MetadataProvider.tmdb
          ? await _api.search(query, kind: _kind)
          : await _theTvdb.search(query, kind: _kind);
      if (results.isEmpty) {
        final fallbackKind = _kind == TmdKind.movie ? TmdKind.tv : TmdKind.movie;
        results = _provider == MetadataProvider.tmdb
            ? await _api.search(query, kind: fallbackKind)
            : await _theTvdb.search(query, kind: fallbackKind);
      }
      final seen = <String>{};
      results.retainWhere((m) => seen.add(m.providerKey));
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
                 hintText: 'Search ${_provider.label}…',

                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _search,
                ),
              ),
              onSubmitted: (_) => _search(),
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
                _search();
              },
            ),
            const SizedBox(height: 8),
            SegmentedButton<MetadataProvider>(
              segments: const [
                ButtonSegment(value: MetadataProvider.tmdb, label: Text('TMDB')),
                ButtonSegment(
                  value: MetadataProvider.theTvdb,
                  label: Text('TheTVDB'),
                ),
              ],
              selected: {_provider},
              onSelectionChanged: (s) {
                setState(() => _provider = s.first);
                _search();
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
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_results == null) {
      return Center(child: Text('Search ${_provider.label} to pick a poster'));
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
             [m.provider.label, if (m.year != null) '${m.year}'].join(' · '),
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
