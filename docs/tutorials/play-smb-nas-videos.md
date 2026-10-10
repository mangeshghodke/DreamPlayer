# Playing SMB / NAS videos with DreamPlayer

DreamPlayer has a **built-in SMB browser on both Android and iPhone/iPad**. Add your
NAS once and browse it like any other folder — no third-party file manager, no
"Open with" hand-off, and nothing is copied or downloaded to your device. Videos
stream directly from the share, so seeking, resume, subtitles and the audio-track
picker all behave exactly as they do for a local file.

The same home **+** menu also has in-app browsers for **WebDAV, FTP/SFTP, Jellyfin**
and **DLNA/UPnP**, so most NAS setups never need the system file picker at all.

## 1. Add your NAS

On **Android and iPhone/iPad** the steps are identical:

1. On the Home screen, tap **+**.
2. Expand **Network sources** and tap **SMB** (on iOS this used to be labelled
   "Network shares").
3. On the server list, tap **+** (or the **Add server** button) and fill in:

   | Field | Notes |
   |---|---|
   | **Name** | Anything you like — shown in the list. Leave blank and your address is used. |
   | **Host** | `192.168.1.50` or a hostname like `nas.local`. Don't include `smb://`. |
   | **Port** | `445` is right for almost every NAS. |
   | **Username** | Your NAS account. Leave both blank to connect as **Guest**. |
   | **Password** | Stored in the Android Keystore / iOS Keychain — never in plain text, and never sent to us. |

4. Tap **Test** to confirm the connection, then **Save**.

Your credentials are saved per server, so you only ever type them once.

### Finding the address automatically

If you don't know the NAS address, tap the **search/discover** button on the server
list. DreamPlayer sweeps your local subnet for machines answering on port 445 and
performs a real protocol handshake against each, so the entries it shows are ones
it has actually spoken to. Tap a result to fill the dialog in for you. The dialog
also reports each server's SMB version (e.g. **SMB 3.1.1**) and identifier.

Saved servers show a **status dot** — green when reachable, red when not.

## 2. Browse and play

1. Tap your server → pick a **share** → navigate folders. Folders are listed before
   files, sorted by name, with sizes shown.
2. Tap a video. Its details page loads (poster, overview, cast and trailers when the
   title is matched by TMDB) and **Play** streams it straight off the NAS.
3. Back returns you to the same folder, so you can pick the next episode.

Nothing is buffered to storage first, so a large library browses instantly and
leaves your device storage alone.

## 3. Keep a folder on your Home screen

If you watch the same show or film folder regularly, pin it once:

1. Navigate to the folder you want.
2. Tap the **bookmark** button in the app bar.
3. The folder becomes a card on Home, with its TMDB artwork, expandable into
   individual season cards.

Pull-to-refresh on Home re-reads local folders, so files you add later show up.

## What works over SMB

Everything the player does for a local file:

- **Full seeking**, with a resume position remembered per file.
- **Subtitles** — any `.srt`/`.ass`/`.vtt`/`.ttml`/`.smi`/`.sub`/`.mpl2` sitting in
  the same folder is detected and offered automatically.
- **Play next episode** within the folder.
- **Watched ticks** per file, and the ability to bookmark a title as watched.
- **Download to device** when you want an offline copy (player **⋮** menu →
  *Download to device*).
- Full codec support — DTS, DTS-HD, TrueHD, E-AC3 and Dolby Vision, same as local.

> **Note:** VobSub (`.idx`/`.sub`) bitmap subtitles are not offered on the native
> engine — use **Play with MPV** for those on Android. See the subtitles section
> of the README.

## Other ways in

### WebDAV, FTP/SFTP, Jellyfin, DLNA

All reachable from **Home → + → Network sources**. They behave the same way: add
the server, browse, play. **DLNA** additionally auto-discovers players and servers
on the network, so a NAS that exposes DLNA needs no configuration at all.

### iOS: the Files app still works

If your NAS is already connected in the **Files** app, you can still hand a file
over: **Files → ⋯ → Connect to Server**, browse to the video, then
**Long-press → Share → Open in "DreamPlayer"**. DreamPlayer registers for all video
containers, including ones iOS has no built-in type for (`.mkv`, `.ts`, `.m2ts`,
`.webm`, `.wmv`, `.flv`, `.mpg`, `.vob` and more).

You can also bookmark a Files-app folder once via **Home → + → Internal storage →
Pick a folder** — useful for a physical USB drive or SD card, which is a different
capability from an SMB share.

### Android: CX Explorer still works

**CX Explorer → tap a video → Open with → DreamPlayer** continues to work. CX
streams over its own local HTTP proxy and DreamPlayer plays it at full speed
(4K HEVC verified at 60 fps, 0 dropped frames).

## Troubleshooting

- **Server not found, or the dot is red:** check the address and that the phone is
  on the same network and subnet. Some routers enable client isolation, which blocks
  device-to-device traffic — that's a router setting, not an app one. Port `445`
  must be reachable, not just `139`.
- **"Permission denied":** SMB2/3 needs a real account. Guest access has to be
  enabled on the NAS itself; leave username and password blank only if it is.
- **Test fails but the share is definitely up:** some NAS setups refuse a bare tree
  connect to `IPC$`. Try the share name directly, or re-test while another client
  is connected to rule out a per-user session limit.
- **Video opens but stalls:** the share streams in real time, so the Wi-Fi link has
  to sustain the file's bitrate. On 5 GHz or a wired connection; look for a
  red "Transcoding"-style warning or heavy buffering on a weak link.
- **Playback is smooth but seeking jumps:** expected on a slow link — a seek has to
  reach the server and re-open the stream at the new offset.
- **iPad: bookmarked folder disappears after a long break:** security-scoped
  bookmarks can expire if the app hasn't been opened; re-pick the folder once.
  In-app SMB servers are unaffected — they re-authenticate from the Keychain.
