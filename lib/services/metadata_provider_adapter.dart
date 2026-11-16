import 'package:flutter/foundation.dart';

import 'tmdb_client.dart';

/// A metadata source that is neither TMDB nor TheTVDB.
///
/// Added for issue #46, part 2 ("custom external metadata APIs", e.g.
/// avdbapi.com). TheTVDB was added as a second provider by teaching
/// `TmdMovie`/`MetadataProvider` about it; an *arbitrary* third-party service is
/// a different shape of problem, because each one has its own response schema.
///
/// So the seam is an adapter: the rest of the app keeps speaking
/// [TmdMovie]/[TmdDetails] and never learns where the data came from, while a
/// new source is written as one implementation of this interface. That is the
/// difference between adding a provider and making providers extensible.
///
/// Registered providers are consulted in registration order, after the built-in
/// ones, and only when [isConfigured] is true - an adapter with no credentials
/// is skipped rather than failing the whole resolution.
abstract class MetadataProviderAdapter {
  /// Stable identifier, persisted in the metadata cache's provider-qualified
  /// keys (`TmdMovie.providerKey` is `<provider>:<kind>:<id>`). Never reuse an
  /// existing provider's name.
  String get id;

  /// Human-readable name for Settings.
  String get label;

  /// Whether this provider has everything it needs to run. An unconfigured
  /// adapter is skipped silently.
  Future<bool> isConfigured();

  /// Currently saved API key, or null. Shown in Settings so the dialog can be
  /// pre-filled with the existing value.
  String? get currentApiKey => null;

  /// Persist [apiKey]; an empty string clears it.
  Future<void> saveApiKey(String apiKey) async {}

  /// One line under the field title in Settings, explaining where to get a key.
  String get credentialsHelp => 'Optional API key for this provider.';

  /// Search for a title. Returns candidates already shaped as [TmdMovie] with
  /// [provider] set to [MetadataProvider.external].
  ///
  /// Returning an empty list means "no confident match", never an error: the
  /// caller falls through to the next provider.
  Future<List<TmdMovie>> search(String query, {TmdKind kind = TmdKind.movie});

  /// Full detail for a [TmdMovie] previously returned by [search].
  Future<TmdDetails?> details(TmdMovie movie);

  /// Seasons and episodes. Optional: a provider that cannot supply them may
  /// return an empty list, and the season screen falls back to filename parsing.
  ///
  /// Defaulted (rather than abstract) so a single-film catalogue - AVDb, or any
  /// source with no notion of a season - is four methods, not six.
  Future<List<TmdSeason>> seasons(TmdMovie movie) async => const [];

  /// Per-episode detail, including stills and cast where available.
  Future<TmdEpisode?> episode(TmdMovie movie, int season, int episode) =>
      Future.value(null);

  /// Resolve a parsed filename to a confident match, or null to fall through.
  ///
  /// Mirrors `TheTvdbClient.bestMatch` so the resolution loop can treat an
  /// adapter exactly like a built-in provider. Built from [search] plus
  /// [details] and defaulted rather than abstract, so a key-less adapter is
  /// still only `search` + `details`.
  ///
  /// Scoring is deliberately simple: the adapter's catalogue is the only one in
  /// play here, so the first exact-or-contained title match wins. A catalogue
  /// that needs real ranking should override this rather than pushing the work
  /// into every caller.
  Future<TmdMatch?> bestMatch(ParsedFileName parsed) async {
    if (!await isConfigured()) return null;
    final hasSeries =
        parsed.isEpisode || (parsed.seriesName?.trim().isNotEmpty ?? false);
    // A single-film catalogue has no notion of a season, so an episode-shaped
    // filename is still matched as a film rather than being rejected outright.
    final query = _queryFor(parsed, hasSeries: hasSeries);
    if (query.isEmpty) return null;

    final hits = await search(query, kind: TmdKind.movie);
    if (hits.isEmpty) return null;

    final wanted = _normaliseTitle(query);
    TmdMovie? best;
    var bestScore = 0.0;
    for (final hit in hits) {
      final candidate = _normaliseTitle(hit.title);
      final score = candidate == wanted
          ? 1.0
          : (candidate.contains(wanted) || wanted.contains(candidate) ? 0.8 : 0.0);
      if (score > bestScore) {
        bestScore = score;
        best = hit;
      }
    }
    if (best == null) return null;

    final fetched = await details(best);
    return TmdMatch(
      TmdMovie(
        id: best.id,
        title: best.title,
        year: best.year,
        posterPath: fetched?.posterPath ?? best.posterPath,
        overview: fetched?.overview ?? best.overview,
        kind: TmdKind.movie,
        provider: best.provider,
        originalTitle: best.originalTitle,
      ),
      bestScore,
    );
  }

  static String _queryFor(ParsedFileName parsed, {required bool hasSeries}) {
    var q = (hasSeries ? (parsed.seriesName ?? parsed.title) : parsed.title).trim();
    // Trailing code/ID the catalogue indexes separately. Querying for it as
    // text returns nothing, so a pure number is sent as `ids=` by `search`.
    if (RegExp(r'^\d+$').hasMatch(q)) return q;
    q = q.replaceAll(RegExp(r'\[[^\]]*\]'), ' ').trim();
    return q;
  }

  /// Lowercase, punctuation-insensitive, so "MIAA-818" == "Miaa 818".
  static String _normaliseTitle(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();

  /// The catalogue code in a file name, e.g. `SVFLA-012` or `MIAA-818`.
  ///
  /// The JAV catalogues (AVDb, r18.dev) are keyed by a studio code, and the
  /// file name is the only place that code appears - so a provider can only
  /// resolve such a file if it sees the ORIGINAL name.
  ///
  /// The parsed title cannot be used: the filename parser treats a trailing
  /// number as a movie-part suffix, so `SVFLA-012.mkv` parses to the title
  /// `SVFLA` and the code is gone. That is why the raw name rides along on
  /// [ParsedFileName.rawName].
  ///
  /// The code is matched anywhere in the name (a studio prefix in brackets is
  /// common: `[FLAVORY] SVFLA-012.mkv`), but a resolution-like number is
  /// rejected, so `HEVC-1080p` is not mistaken for a code.
  static String? catalogueCodeIn(String name) {
    // Strip a trailing extension so the code's last digit is not followed by
    // a dot-letter sequence.
    var cleaned = name.trim();
    final dot = cleaned.lastIndexOf('.');
    if (dot > 0 && cleaned.substring(dot + 1).length <= 4) {
      cleaned = cleaned.substring(0, dot);
    }
    // Bracketed groups hold the studio, not the code.
    cleaned = cleaned.replaceAll(RegExp(r'[\[\(\{][^\]\)\}]*[\]\)\}]'), ' ');
    final match = RegExp(
      r'(?<![A-Za-z0-9])([A-Za-z]{2,6})[-_ ]?(\d{2,5})(?![A-Za-z0-9])',
    ).firstMatch(cleaned);
    if (match == null) return null;
    final digits = match.group(2)!;
    // A resolution is not a catalogue number.
    if (const {'480', '720', '1080', '1440', '2160', '4320'}.contains(digits)) {
      return null;
    }
    // Neither is a year: `The Matrix 1999` is a title, not a code.
    if (digits.length == 4) {
      final asYear = int.tryParse(digits);
      if (asYear != null && asYear >= 1900 && asYear <= 2099) return null;
    }
    return '${match.group(1)!.toUpperCase()}-$digits';
  }
}

/// Registry of [MetadataProviderAdapter] implementations.
///
/// Kept deliberately small: a static list plus a notifier, because the set
/// changes at startup (after Settings loads credentials) rather than per frame.
class MetadataProviderRegistry {
  MetadataProviderRegistry._();

  static final MetadataProviderRegistry instance = MetadataProviderRegistry._();

  final List<MetadataProviderAdapter> _adapters = [];
  final List<VoidCallback> _listeners = [];

  /// Adapters in consultation order.
  List<MetadataProviderAdapter> get adapters => List.unmodifiable(_adapters);

  void register(MetadataProviderAdapter adapter) {
    if (_adapters.any((a) => a.id == adapter.id)) return;
    _adapters.add(adapter);
    _notify();
  }

  void unregister(String id) {
    _adapters.removeWhere((a) => a.id == id);
    _notify();
  }

  MetadataProviderAdapter? byId(String id) {
    for (final adapter in _adapters) {
      if (adapter.id == id) return adapter;
    }
    return null;
  }

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List<VoidCallback>.from(_listeners)) {
      listener();
    }
  }

  /// Adapters that currently have usable credentials, in order.
  ///
  /// Skipping unconfigured ones here is what keeps a user with no AVDb key from
  /// seeing a failed request on every single metadata lookup.
  Future<List<MetadataProviderAdapter>> configured() async {
    final result = <MetadataProviderAdapter>[];
    for (final adapter in _adapters) {
      try {
        if (await adapter.isConfigured()) result.add(adapter);
      } catch (_) {
        // A misbehaving adapter must not block the others.
      }
    }
    return result;
  }
}