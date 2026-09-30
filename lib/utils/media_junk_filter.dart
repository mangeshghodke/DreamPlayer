/// Filters out non-content files and directories that media libraries are
/// littered with: extras/featurettes folders, artwork sidecars, player resume
/// state, and YouTube-dump trailers.
///
/// This matters for metadata fetching, not just tidiness. A `Featurettes/`
/// subfolder inside a movie folder makes the movie look like a *container*
/// (it has subdirs), so the movie never becomes its own library card, and each
/// of the 13 trailers inside it fires its own doomed TMDB search. Excluding
/// the directory fixes both the card and the search storm.
library;

/// Directory names that never contain the actual movie/episode.
///
/// Matched case-insensitively against the whole directory name, after
/// normalising spaces/dots/underscores to single spaces — so `Special
/// Features`, `special_features` and `Special.Features` all hit.
const Set<String> junkDirectoryNames = {
  // Extras / bonus material
  'featurettes', 'featurette', 'extras', 'extra', 'bonus', 'bonus features',
  'special features', 'specialfeatures', 'special feature', 'specialfeature',
  'behind the scenes', 'behindthescenes', 'behind the scene', 'bts',
  'interviews', 'interview', 'making of', 'the making of', 'commentary',
  'deleted scenes', 'deleted scene', 'alternate takes', 'bloopers', 'blooper',
  'blooper reel',
  // Trailers / samples
  'trailer', 'trailers', 'teaser', 'teasers', 'promo', 'promos', 'sample',
  'samples', 'proof', 'preview', 'screener',
  // Non-video assets
  'artwork', 'art', 'covers', 'cover', 'posters', 'poster', 'backdrops',
  'logo', 'logos', 'subs', 'sub', 'subtitles', 'subtitle', 'soundtrack',
  'soundtracks', 'screenshots', 'screens', 'theme',
  // Junk directories from players / sync tools
  '@eadir', '_deleted_by_bep', '.thumbnails', 'thumbs', 'thumbs.db',
  'lost+found', 'recycle bin',
};

/// Filename prefixes that mark a file as promotional / non-narrative content.
///
/// Only applied when what follows the prefix is a number or a short qualifier,
/// so a real feature film like "Trailer Park Boys" is not swallowed by a long
/// descriptive title.
const List<String> junkFilePrefixes = [
  'trailer', 'teaser', 'featurette', 'sample', 'proof', 'screener', 'preview',
  'blooper', 'bloopers', 'deleted scene', 'deleted scenes', 'alternate take',
  'alternate takes', 'behind the scene', 'behind the scenes', 'the making of',
  'making of', 'interview', 'commentary', 'press featurette', 'promo',
  'angels with', // Home-Alone-style extra titles seen in the wild
];

/// File extensions that are never playable content.
const Set<String> junkFileExtensions = {
  '.xml', '.nfo', '.txt', '.sfv', '.url', '.m3u', '.m3u8', '.log', '.tmp',
  '.part', '.crdownload', '.download', '.ini', '.db', '.cue',
  // Sidecar subtitles. The player still auto-pairs these natively when it
  // opens a video (Android `SubtitleFormats.findSiblingSubtitles` / iOS
  // `ExternalSubtitleTrack`), so hiding them from the listing costs nothing.
  '.srt', '.ass', '.ssa', '.vtt', '.ttml', '.dfxp', '.smi', '.sub', '.idx',
  '.sup', '.usf',
  // Artwork sidecars: `folder.jpg`, `backdrop.jpg`, `logo.png`,
  // `... -poster.jpg`. Not videos, but listing them as playable rows is noise.
  '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.tbn', '.tif', '.tiff',
};

/// Qualifiers that keep a junk prefix unambiguous. `Trailer 1` / `Trailer HD`
/// are extras; `Trailer Park Boys` is a real feature film and must survive.
const Set<String> _junkPrefixQualifiers = {
  'reel', 'final', 'cut', 'version', 'hd', 'sd', '4k', '1080p', '2160p',
  'remastered', 'extended', 'teaser',
};

/// True for directories that should never be scanned or listed.
bool isJunkDirectory(String name) {
  if (name.isEmpty) return true;
  // Hidden entries (`.thumbnails`, `.DS_Store`, `.Trash`) are tool state.
  if (name.startsWith('.')) return true;
  final normalized = name
      .toLowerCase()
      .replaceAll(RegExp(r'[._]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return true;
  if (junkDirectoryNames.contains(normalized)) return true;
  return false;
}

/// True for files that are artwork, subtitles, resume state or trailers.
bool isJunkFile(String name) {
  if (name.isEmpty) return true;
  if (name.startsWith('.')) return true;

  final dot = name.lastIndexOf('.');
  final base = (dot > 0 ? name.substring(0, dot) : name)
      .toLowerCase()
      .replaceAll(RegExp(r'[._]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final ext = dot > 0 ? name.substring(dot).toLowerCase() : '';

  if (junkFileExtensions.contains(ext)) return true;
  if (base.isEmpty) return true;

  // A junk *prefix* only wins when what follows it is a number or a short
  // qualifier, so `Trailer 1` is filtered while `Trailer Park Boys` — a real
  // feature film — is not.
  for (final prefix in junkFilePrefixes) {
    if (base == prefix) return true;
    if (!base.startsWith('$prefix ')) continue;
    final rest = base.substring(prefix.length).trim();
    if (rest.isEmpty) return true;
    if (RegExp(r'^[\d\s.]+$').hasMatch(rest)) return true;
    if (_junkPrefixQualifiers.contains(rest)) return true;
  }
  return false;
}
