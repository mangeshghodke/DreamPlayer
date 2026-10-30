# App Store Connect — "What's New"

Paste-ready release notes for the **What's New** field in App Store Connect
(App Store Connect → your app → the version → *What’s New*).

- One section per version, newest first.
- Plain language, no jargon, no internal filenames, no bug numbers. The App
  Review guidelines expect release notes a user can act on.
- **Hard limit: 4000 characters.** Each block below is well under that; the
  character count is noted per version so you can check after editing.
- Anything you are unsure of shipping should be left out — you cannot walk a
  note back once the build is live.

Character counts are kept in a table here rather than inside a version block, so
that copying a block for App Store Connect can never pick up a stray note:

| Version | Build | Characters (limit 4000) |
|---|---|---|
| 0.5.5 | 60 | 1644 |
| 0.5.4 | 56 | 1756 |
| 0.5.2 | 51 | 1549 |
| 0.5.1 | 36 | 3833 |

A count is the length of the text you would paste — the block from its "New:"
or "Fixed:" line down to its last character, including the final newline — so
it can be reproduced with a plain character count after any edit.

---

## 0.5.5 (build 60)

New:
• List or Grid in the network browsers. The three-dot menu at the top right of
  the SMB, WebDAV, FTP, DLNA and Jellyfin browsers now has a View entry: List
  for the familiar rows, Grid for tiles with artwork — folders, films and
  episode stills. The choice applies to every network browser at once, takes
  effect straight away and is remembered.
• A second optional catalogue for titles the main one does not carry. It needs
  no account, key or sign-in. Switch it on in Settings → Metadata and films are
  matched from the catalogue code in the file name. What it brings is the same
  as any other match: poster, cast, release date, studio and genres.
• The Get info, Fix match and Group poster dialogs now search that optional
  catalogue too, alongside the ones already built in. They previously knew
  only about the main catalogue, so a key-less setup was told to add a key by
  the very dialog that could have done the job.
• A warning when the screen is pushed past 80% brightness, saying that it
  drains the battery faster. It appears once, at the moment you cross the line,
  and never blocks playback.

Fixed:
• Picking a match from the optional catalogue could load the wrong film. The
  poster and description were fetched from the main catalogue instead, which
  answered with an unrelated title. The details now come from the catalogue
  that matched.
• A catalogue code written without its separator found nothing. The
  separator-less spelling is now tried as well, so both forms work.
• Some titles showed stray characters in their original name, because the
  optional catalogue leaves them in the text it returns.

---

## 0.5.4 (build 56)

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

---

## 0.5.2 (build 51)

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

## 0.5.1 (build 36)


Chapter navigation, made visible. Files that carry chapter markers — anime
openings, endings and previews are the common case — now show a tick on the
seekbar at every boundary, so you can see where they are instead of hunting.

New:
• Previous/next chapter buttons either side of play. The previous button
  restarts the chapter you are in when you are more than three seconds into it
  and steps back when you are not, so pressing it twice walks back rather than
  sticking — the same as a CD player.
• Double-tapping the seekbar jumps to the next chapter.
• Each jump names the chapter it landed on ("Next chapter · Opening").

The buttons appear only for files that actually have chapters. Plenty of films
have no chapter data at all, and those show nothing, as before.

• Chapters now work on network shares. Previously they only appeared for videos
  stored on the device, so a film on your NAS showed no markers and no buttons at
  all even though the very same file played with chapters from local storage.
  SMB, WebDAV and FTP sources all behave like local storage now.

In-app SMB for iPhone and iPad. Connect to a NAS or any SMB share from inside
the app instead of bouncing out to the system file picker: add a server,
browse its shares and folders, pin a folder to your home screen, and play
straight from the browser.

Also new:
• LAN server discovery — DreamPlayer sweeps your network for reachable SMB
  servers and shows each one's SMB version, so you can tell what you are
  looking at before connecting.
• Reachability dots — a saved server shows green when it is online and red when
  it is not. Previously the indicator was always red on iPhone and iPad.
• Remembered share names — a share with an unusual name can be added by hand once
  and will still be found the next time you open the server.
• Cleaner folder listings — Samba's "print$" printer share and the "." and ".."
  parent-directory entries no longer clutter the file list.
• Server named for you — add a server without typing a name and it is listed as
  its IP address.

Artwork, everywhere:
• One poster per film — change a poster or backdrop once and it now shows
  everywhere that title appears: the SMB page, the home card and Continue
  Watching. For series, a show or season pick reaches its episodes, while
  different seasons can still have their own artwork.
• Full artwork on iPad — a title's header image now shows the whole picture in
  portrait on any screen size, rather than a narrow cropped strip on a tablet.

Fixed:
• Opening a title's details screen could leave the app unresponsive for up to a
  minute — the loading spinner stopped dead and touches did nothing — before the
  page finally appeared. It was worst on a large library, and most likely when
  opening a title you had not opened before. Playback itself was never affected.
• 4K films were sometimes labelled "2K". Many 2160p releases are trimmed to a
  wide cinematic shape to save space, which leaves the picture a couple of pixels
  under the usual 4K width; those are correctly shown as 4K now. The resolution
  shown on a title's details page and in the player now always agree.
• Opening a file from an SMB share could fail the first time with "could not
  open the file". This is resolved.
• Bookmarked SMB folders could reconnect to the wrong share, which prevented
  resuming files inside them. If a folder still misbehaves, remove it from your
  home screen and add it again.
• Resuming a video that had a non-default audio track selected started from the
  beginning. Resume now lands where you left off.
• Resuming a video no longer plays a moment of the default audio track before
  switching to the one you chose.
• Series artwork no longer changes a few seconds after opening an episode, which
  left it out of step with the card it was opened from.

---

## How to use this file

1. Copy the block for the version you are submitting.
2. Paste it into the *What's New* field.
3. Start a new section at the top for the next version.

Keep the "Fixed" items phrased from the user's point of view ("opening a file
could fail") rather than as a changelog entry ("fixed the SMB open path"). Users
do not know or care which path is broken, only what they saw.