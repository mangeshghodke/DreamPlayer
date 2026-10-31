# iOS release notes (App Store Connect "What's New")

**Use this file for App Store Connect What's New — NOT `CHANGELOG.md`.**

`CHANGELOG.md` is written for the Android sideload audience (GitHub Releases)
and deliberately contains things App Store review rejects. Guideline 2.3.10
("Accurate Metadata") flagged 0.5.1 (36) because the notes named another
platform and carried engine/implementation detail.

## Rules for this file

- **Never name another platform.** No "Android", no "on Android it's...".
  Every iOS user has an Android phone; it is not a comparison they asked for.
- **No engine names.** "MPV", "libmpv", "Media3", "ExoPlayer" are Android
  implementation detail. Describe the behaviour instead: "plays", "the
  fallback player".
- **No internal identifiers.** No `SystemCodec`, `Activity`, `HTTP 400`,
  pixel widths, dB figures, class or function names, or commit details.
- **Only ship what iOS users got.** A large part of each changelog entry is
  Android-only. If it is not visible or reachable on iOS, it does not go here.
- Lead with user-visible behaviour, one line per change, ~4000 character cap.

## Which build each section describes

A section must only claim what is **actually in that build**, not what is on
`main`. TestFlight 43 was commit `9d75ae3`; build 49 (commit `a550985`) added
only the folder-first share ordering; build 50 (`51aeb6d`) carried an earlier
version of the episode label as a separate chip with its own setting, and build
51 (`5a7b47d`) replaces it with the title line shipped here. Anything committed
after the section's build belongs in the *next* section.

An earlier draft of this file advertised chapter markers in 0.5.1, which was
true of the intended build but not of the one that was reviewed. Verify with
`git log <build-commit>..main` before writing a section, not `git log v0.5.1..main`.

---

## 0.5.5

New:
• Night mode and Bass boost. Night mode compresses the dynamic range so
  quiet dialogue comes up without the loud moments getting louder, and Bass
  boost lifts the low end. They are part of the subscription; switching them
  off is always free.
• This version needs iOS 18 or newer. The playback engine now uses iOS 18
  system APIs directly, so the app's own minimum moved with it.
• List or Grid view in the shared-folder browsers. The three-dot menu at the
  top right of the SMB, WebDAV, FTP, DLNA and Jellyfin browsers now has a
  View entry: List for the familiar rows, Grid for tiles with artwork —
  folders, films and episode images. The choice applies to every one of those
  browsers at once and is remembered.

• Pushing the screen brightness past 80% now flashes a short warning that it
  drains the battery faster, the first time you cross that point.

• Another key-free film catalogue is available in Settings → Metadata. It
  matches a film by its catalogue code — SVFLA-012 and SVFLA012 are the same
  film — and brings the poster, cast, release date, studio and genres.

Fixed:
• The volume swipe no longer goes past 100% on iPhone and iPad, and the
  "Volume boost" setting is gone there. Pushing it past 100% had to rebuild
  the audio session, which reloaded the picture on every step of the swipe.
  Night mode and Bass boost are unchanged.
• After unlocking the iPad — or coming back to the app — the interface no
  longer looks stretched for a moment.
• A file on a network share keeps playing after the iPad has been locked: the
  app reconnects to the share on its own, and the audio track you had chosen
  is restored instead of the file's default one.
• The Get info and Fix match dialogs now search the key-free catalogues
  alongside the others, so a film can be matched even without a key for the
  catalogues that need one.
• A film matched through one of those catalogues keeps its own details. The
  poster and synopsis could previously be fetched from a different catalogue
  and show an unrelated film.

---

## 0.5.4

New:
• Search your library from the Home screen. A search button matches shows,
  seasons, episodes and films by title, file name or episode code as you type —
  accents and capitals do not matter — and works without a connection. Every
  result opens the same page as the matching card on the Home screen.
• Keyboard shortcuts when a hardware keyboard is attached: K or Space to play
  and pause, J and L to skip back and forward ten seconds, F for fullscreen,
  and the left and right arrows to skip while the controls are hidden.
• A system AirPlay button in the player, so a speaker or TV can be picked
  without leaving the app. Audio always follows the chosen route; for some
  file types only the sound can be sent and the picture stays on this device.
• The Now Playing card on the lock screen and in Control Center now shows the
  matched poster instead of a blank tile, and its skip-back and skip-forward
  buttons jump ten seconds, stopping cleanly at either end. The card now also
  shows the resolved title — with the season and episode (e.g. S02E05 · The
  Long Way Home) — instead of the raw file name.
• The 4:3, 16:9, 1.85:1 and 2.39:1 choices in the aspect-ratio menu now give
  the video exactly that frame instead of approximating it on the full screen.
  Fit, Crop and Stretch are unchanged.
• Subtitles now look the way you want them to. Settings → Subtitles covers the
  font, size, text colour and opacity, background colour and opacity, edge
  style (outline, drop shadow or none), vertical position and sync delay, with
  a live preview that updates as you go. Every text subtitle format follows the
  style; image-based subtitles keep their own artwork. The same screen is one
  tap away from the player's subtitle menu.
• The subtitle font list now includes the full Google Fonts catalogue, with
  search and every name previewed in its own typeface, plus nine families that
  are built into the app and work with no connection at all. A chosen family
  applies to the video itself, not only to the preview — including while
  watching something from a shared folder.

Fixed:
• A font downloaded from the catalogue could be ignored by the player and the
  subtitles would fall back to the default typeface. Families whose names
  contain a space were the most likely to hit this.
• Chapter markers on the seekbar and the previous/next chapter buttons now
  stay visible after changing the audio track.
• Changing the audio track no longer plays the default track for a moment
  before switching to the one you chose.

---

## 0.5.2

New:
• Five app icons to choose from in Settings → Appearance. Pick the original logo
  and wordmark, the logo on its own, or the logo in red, green or cyan; the
  change applies straight away, with no reinstall. The wordmark-free logo is
  handy when your device already prints the app name underneath the icon.
• An optional second metadata catalogue in Settings → Metadata, for titles the
  main catalogue does not carry. It needs no account, key or sign-in and matches
  films by name, release code or numeric ID, with poster art and details like
  any other match. It is off until you switch it on, covers films only, and
  titles that already match are unaffected.
• The player now names the episode you are watching: the show title is
  followed by the season and episode, such as S02E05 · The Long Way Home, on
  the same line. The code appears for every episode, and the episode name
  whenever one is available. Films are unchanged.

Fixed:
• The icon picker could fail to open on smaller screens.
• The file browser no longer offers a Delete option on iPhone and iPad, where it
  had no effect.
• Pulling down to refresh the list of shared folders no longer reports that the
  folder could not be read.
• Every shared folder on the server now appears in the list, not just folders
  with common names.
• Restoring a purchase now asks the App Store directly and re-reads what your
  account owns, instead of relying on a delayed notification.
• Folders now come before files when you browse a shared folder, each in
  alphabetical order.

---

## 0.5.1

• In-app SMB on iPhone and iPad — browse shares, pin folders to Home and
  play, without leaving the app.

• Fixed a freeze that could make a title's details page hang for up to a
  minute on iPhone and iPad.

• Chapter markers now appear on the seekbar, with previous/next chapter
  buttons either side of play/pause. They now work on network shares and
  in-app SMB as well as local files.

• Browsing an SMB share is faster and more reliable: files open first
  time, bookmarked folders reconnect to the right share, printer and
  parent-folder entries no longer appear in listings, and saved servers
  show green when reachable. Servers saved without a name now show their
  address.

• Resume position and audio track selection now survive switching audio
  track, so playback no longer restarts from the beginning.

• Episode and movie artwork appears in more places and loads faster.

• Adjustable episode-list thumbnails (Settings → Layout), and titles stay
  readable offline.

• Changing a poster or backdrop now applies everywhere that title appears.

• Fixed artwork and layout issues on larger iPad screens.
