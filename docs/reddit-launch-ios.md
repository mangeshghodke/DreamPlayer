# Reddit launch posts — DreamPlayer for iOS

**Post AFTER 0.5.0 is approved and live.** Reason in the note at the bottom —
read it before posting.

App Store link (already live, use this):
`https://apps.apple.com/in/app/dreamplayer-video-player/id6813066889`

All three drafts: same App Store link, no link in the title, transparency that
you're the developer, honest limitations included (that part is what makes the
post land on Reddit rather than get removed).

---

## 1. r/iosapps

**Title**

```
[Made for iOS] DreamPlayer — a local video player that actually does Dolby Vision and lossless audio
```

**Body**

```
I make this one, so take it with a grain of salt — but the problem it solves is
one I kept hitting myself, so I thought it might be useful to someone else.

This is a player for your OWN files. Nothing to sign up for, no streaming
service, no library sitting on someone else's servers. Your files, your NAS, your
disk.

What it does that I couldn't find elsewhere on iOS:

• Dolby Vision and HDR10/HDR10+/HLG passthrough, on hardware that supports it.
  Verified on an iPad Pro M2. This was the main reason I built it — the
  built-in players handle HDR inconsistently and most third-party ones just
  don't try.

• Real lossless audio: DTS-HD, TrueHD, Dolby E-AC3, and 24-bit multichannel
  FLAC, with mid-playback track switching.

• MKV, TS and other containers AVPlayer won't open natively — it uses an
  FFmpeg demux layer for those, so a .mkv doesn't need converting first.

• Your NAS, several ways: SMB shares through the Files app's own "Connect to
  Server", plus WebDAV, FTP/SFTP, Jellyfin and DLNA. Also works with
  "Open with" from any file manager.

• Sidecar subtitles just work — drop a .srt/.ass next to the video and it
  attaches automatically, correctly matched. Picture-in-picture too.

What it does NOT do, so you can decide if it's worth your time:

• No streaming services. It's for files you already have.
• Dolby Vision output depends on your display, obviously.
• No Android-style codec soup — if the iPad's own hardware can't decode
  something, the app can't fix that.
• Requires iOS/iPadOS 17 or later.

On cost: browsing, playback, all of the sources, subtitles and Dolby
Vision/HDR are free and stay free. There's a 7-day trial that unlocks the
extras (playback speed, A-B loop, sleep timer, subtitle styling, online
subtitle search, download to device), and a subscription after that if you
want them. Nothing I've listed as free is behind that.

https://apps.apple.com/in/app/dreamplayer-video-player/id6813066889

Happy to answer questions about the technical side — especially how the HDR
path works, since that took some digging.
```

---

## 2. r/AppStore

**Title**

```
New on the App Store: DreamPlayer, a local video player for iPhone and iPad with Dolby Vision + lossless audio
```

**Body**

```
Just released DreamPlayer on the App Store. I'm the developer.

Short version: it's a video player for your own files, and it takes HDR and
lossless audio seriously on iOS.

• Dolby Vision, HDR10, HDR10+ and HLG passthrough on capable hardware
  (verified on iPad Pro M2)
• DTS-HD, TrueHD, Dolby E-AC3, and 24-bit multichannel FLAC
• MKV / TS / WebM via an FFmpeg demux layer, so you don't have to remux
• Plays from NAS: SMB via the Files app, plus WebDAV, FTP/SFTP, Jellyfin, DLNA
• Automatic sidecar subtitles (.srt, .ass, .vtt and friends), PiP, chapters

It works on iPhone and iPad, needs iOS 17+.

Free to browse and play everything, including all the HDR formats. A 7-day
trial covers the extras (playback speed, A-B loop, sleep timer, subtitle
styling, online subtitle search, download to device), with an optional
subscription after that. Android version exists too and is free.

https://apps.apple.com/in/app/dreamplayer-video-player/id6813066889

Feedback welcome — especially on devices I haven't tested against.
```

---

## 3. r/ipad

**Title**

```
iPad app I made: local video player with Dolby Vision passthrough, lossless audio, and NAS support
```

**Body**

```
Made this because I wanted my iPad to play my own library properly — including
the Dolby Vision and DTS-HD files that the built-in player handles badly or not
at all. Verified Dolby Vision and HDR10 passthrough on an iPad Pro M2.

iPad-relevant bits:

• Real HDR passthrough (DV, HDR10, HDR10+, HLG) rather than tone-mapped SDR
• DTS-HD / TrueHD / E-AC3 / 24-bit multichannel FLAC
• PiP, chapter support, and sidecar subtitles that just attach themselves
• Reads NAS shares — SMB through the Files app's "Connect to Server", so no
  third-party server app needed. WebDAV, FTP/SFTP, Jellyfin and DLNA also work.
• AirPlay for the TV when you want the big screen

It plays files you already own — no streaming services, no sign-up.

Free to browse, play, and use all the HDR formats. 7-day trial for the extras
(speed, A-B loop, sleep timer, subtitle styling, online subtitle search,
download), optional subscription after.

https://apps.apple.com/in/app/dreamplayer-video-player/id6813066889

Would love feedback from people with iPads I haven't been able to test on.
```

---

## Before you post — read this

**Timing.** The live App Store build right now is **0.4.8**, which has the
paywall disabled and is completely free. **0.5.0** turns the paywall on. If
you post now, people install the free 0.4.8, then get upgraded to the paywall
build. That's legal — they get the 7-day trial — but on Reddit, "it was free
when they said so" is exactly the comment thread that kills a post. Wait for
0.5.0 to be approved and live, then post. The drafts above describe 0.5.0
accurately.

**Every draft is transparent** that you made the app. Don't hide it. Reddit
users find astrotuffed posts fast and the response is disproportionately
hostile.

**On r/iosapps specifically**, check the current self-promotion rule before
posting — they change it. If there's a "no self-promotion" day or a required
flair/tag, use it or wait. Getting this wrong is the fastest way to have the
post removed and the account flagged.

**Don't post all three at once.** Same text to three subs reads as spam
coordination. Space them out — 0.5.0 live, post r/iosapps; a few days later
r/ipad; then r/AppStore. And actually participate in the comments. A dev who
answers technical questions gets a very different reception than one who
disappears after posting.

**If it gets traction**, the comments asking "is this just a wrapper?" are
inevitable. The FFmpeg demux layer, the native HDR passthrough path, and the
Keychain-persisted trial are all real answers to that.
