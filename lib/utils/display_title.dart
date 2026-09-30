import '../models/video_item.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';

/// The title to show for a video, preferring what the metadata provider
/// resolved over the raw filename.
///
/// Lives here so the poster card and the list row can never disagree again —
/// an earlier version of the list view printed `video.title` directly, so
/// "Interstellar.2014.IMAX.2160p.UHD.mkv" showed its filename while the grid
/// beside it showed "Interstellar".
String videoDisplayTitle(VideoItem video, TmdMeta? meta) {
  final resolved = meta?.movie.title ?? '';
  return resolved.isNotEmpty ? resolved : video.title;
}

/// The title to show for a library folder or series group.
///
/// Precedence mirrors the poster card exactly:
/// 1. a manual group name the user typed ([displayNameOverride]),
/// 2. the season's own name for a single-season folder ("Strike the Blood II"),
/// 3. the provider's series/movie title,
/// 4. a Jellyfin-provided name,
/// 5. the raw folder name.
String folderDisplayTitle({
  required LibraryFolder folder,
  TmdMeta? meta,
  String? displayNameOverride,
  String? jellyfinName,
}) {
  if (displayNameOverride != null && displayNameOverride.isNotEmpty) {
    return displayNameOverride;
  }
  final season = meta?.folderSeason;
  final seasonName =
      season != null ? meta?.seasons[season]?.name : null;
  if (seasonName != null && seasonName.isNotEmpty) return seasonName;
  final movieTitle = meta?.movie.title ?? '';
  if (movieTitle.isNotEmpty) return movieTitle;
  if (jellyfinName != null && jellyfinName.isNotEmpty) return jellyfinName;
  return folder.name;
}
