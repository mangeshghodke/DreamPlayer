import 'package:flutter/material.dart';

import '../services/artwork_override.dart';
import '../services/tmdb_client.dart';
import '../widgets/cached_image.dart';

/// "Change poster" / "Change backdrop" picker (issue #33).
///
/// Shows every candidate from every configured provider in one grid, grouped by
/// provider, and persists the tap through [TmdService.setArtwork] so the pick
/// is applied at read time by `metaFor` — i.e. it sticks across re-resolution
/// and reaches every card and header that shows this item, not just the screen
/// it was made on.
class ArtworkPickerSheet extends StatefulWidget {
  const ArtworkPickerSheet({
    super.key,
    required this.identityKey,
    required this.kind,
  });

  final String identityKey;
  final ArtworkKind kind;

  /// Opens the picker and returns true when a pick (or a reset) was made.
  static Future<bool?> show(
    BuildContext context, {
    required String identityKey,
    required ArtworkKind kind,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16161A),
      builder: (_) => ArtworkPickerSheet(identityKey: identityKey, kind: kind),
    );
  }

  @override
  State<ArtworkPickerSheet> createState() => _ArtworkPickerSheetState();
}

class _ArtworkPickerSheetState extends State<ArtworkPickerSheet> {
  late Future<({List<MetaImage> posters, List<MetaImage> backdrops})> _future;

  @override
  void initState() {
    super.initState();
    _future = TmdService.instance.artworkFor(widget.identityKey);
  }

  ArtworkKind get _kind => widget.kind;

  bool get _isPoster => _kind == ArtworkKind.poster;

  String get _title => _isPoster ? 'Change poster' : 'Change backdrop';

  Future<void> _pick(MetaImage image) async {
    await TmdService.instance.setArtwork(widget.identityKey, _kind, image);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _reset() async {
    await TmdService.instance.resetArtwork(widget.identityKey, _kind);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overridden = TmdService.instance.hasArtworkOverride(
      widget.identityKey,
      _kind,
    );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (overridden)
                    TextButton.icon(
                      onPressed: _reset,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text('Default'),
                    ),
                ],
              ),
            ),
            Flexible(
              child: FutureBuilder(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final data = snap.data ??
                      (posters: <MetaImage>[], backdrops: <MetaImage>[]);
                  final images = _isPoster ? data.posters : data.backdrops;
                  if (images.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                      child: Text(
                        _isPoster
                            ? 'No posters available for this title.'
                            : 'No backdrops available for this title.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  return _buildGrid(context, images);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List<MetaImage> images) {
    // Group by provider so a title with art from both is readable — the user
    // asked for "every configured provider" in one list, and Nova separates
    // them the same way.
    final byProvider = <MetadataProvider, List<MetaImage>>{};
    for (final image in images) {
      byProvider.putIfAbsent(image.provider, () => []).add(image);
    }
    const labels = {
      MetadataProvider.tmdb: 'TMDB',
      MetadataProvider.theTvdb: 'TheTVDB',
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      children: [
        for (final entry in byProvider.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
            child: Row(
              children: [
                Text(
                  labels[entry.key] ?? entry.key.name,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Colors.white70,
                        letterSpacing: 0.6,
                      ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${entry.value.length}',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: Colors.white38),
                ),
              ],
            ),
          ),
          _rows(context, entry.value),
        ],
      ],
    );
  }

  Widget _rows(BuildContext context, List<MetaImage> images) {
    final selected = ArtworkOverrideStore.overrideFor(
      widget.identityKey,
      _kind,
    )?.url;
    // Posters are portrait and backdrops are landscape; a fixed aspect ratio
    // per kind keeps the grid from reflowing wildly across mixed sources.
    final ratio = _isPoster ? 2 / 3 : 16 / 9;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: images.length,
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _isPoster ? 140 : 210,
        childAspectRatio: ratio,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemBuilder: (context, index) {
        final image = images[index];
        final url = image.displayUrl(_isPoster ? 342 : 780);
        final isSelected = image.url == selected;
        return InkWell(
          onTap: url.isEmpty ? null : () => _pick(image),
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  color: Colors.white.withValues(alpha: 0.06),
                  child: url.isEmpty
                      ? const Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white38,
                          ),
                        )
                      : CachedImage(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white38,
                            ),
                          ),
                        ),
                ),
              ),
              if (isSelected)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check,
                            size: 14,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
