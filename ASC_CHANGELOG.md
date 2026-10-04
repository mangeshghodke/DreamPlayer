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

---

## 0.5.1 (build 28)

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

The buttons appear only for files that actually have chapters.

Also fixed:
• Opening a title's details screen could freeze the app for several seconds —
  the loading spinner stopped moving and the app stopped responding. It was
  most noticeable on a large library, when opening a title from a network
  share. Playback itself was never affected.

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
  its IP address, as on Android.

Artwork, everywhere:
• One poster per film — change a poster or backdrop once and it now shows
  everywhere that title appears: the SMB page, the home card and Continue
  Watching. For series, a show or season pick reaches its episodes, while
  different seasons can still have their own artwork.
• Full artwork on iPad — a title's header image now shows the whole picture in
  portrait on any screen size, rather than a narrow cropped strip on a tablet.

Fixed:
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