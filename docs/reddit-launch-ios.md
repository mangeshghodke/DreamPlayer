# Reddit launch posts — DreamPlayer for iOS

> **REVISED.** An earlier draft claimed "Dolby Vision and HDR are free and
> stay free". **That was false** — Dolby Vision / HDR10 / HDR10+ / HLG is
> gated behind the subscription after the 7-day trial (`_checkHdrGate()` in
> `player_screen.dart`). Do not publish the old wording.

**Posting timing — you can post now.** The paywall and the 7-day trial are
already live in 0.4.8, so the drafts below describe what someone gets today,
not a future state. 0.5.0 only adds the Keychain mirror of the trial start
time (so the trial survives a reinstall) — the trial itself, and the Dolby
Vision / HDR gate, are unchanged.

App Store link (use this, it's already live):
`https://apps.apple.com/in/app/dreamplayer-video-player/id6813066889`

Every draft: link at the end (not the title), transparent that you're the
developer, honest limitations, and **honest about the trial** — which is also
the strongest selling angle, since Infuse (the closest comparable) locks
Dolby Vision behind Pro permanently.

## Where Infuse genuinely wins

I keep seeing Infuse recommended, and it deserves the reputation — but it locks
Dolby Vision and Dolby/DTS audio behind Pro. DreamPlayer is cheaper and less
frictional, but Infuse is not the weaker app:

- **Apple TV, Mac and VisionOS.** Infuse runs everywhere Apple does. DreamPlayer
  is iPhone and iPad only.
- **Chromecast.** DreamPlayer has AirPlay, not Chromecast.
- **iCloud and Trakt sync** of library, settings, watched history and progress
  across devices. DreamPlayer has no cloud sync at all.
- **A much longer format list** — BDMV, ISO/IMG, VIDEO_TS, MXF, VC1, WMV, DVR-MS,
  plus NFS, FTPES/FTPS and Plex. DreamPlayer's FFmpeg layer covers MKV/TS/AVI/WebM
  well, but it isn't that broad.
- **13 cloud providers** integrated directly. DreamPlayer does NAS and
  self-hosted servers, not consumer cloud drives.
- **Spatial audio**, which DreamPlayer doesn't have on iOS yet.
- It's been around since 2013 and has the polish and review count that buys.

If you want one app for the whole Apple household including the TV, Infuse is
the better buy. If you play on iPad and Android and want the trial to actually
cover the HDR, this is the cheaper and more honest version of the same thing.

## 0.7 How it compares

Checked against each vendor's own App Store listing on 28 Sep 2026 — prices
change, so treat these as approximate and go look for yourself.

| | **DreamPlayer** | **Infuse** | **VLC** | **nPlayer** |
|---|---|---|---|---|
| Price | Free · ₹199/mo · ₹1,499/yr · **₹4,999 once** | Free · $1.99/mo · $19.99/yr · $119.99 once | **Free, always** | **$4.99 once** |
| Dolby Vision / HDR | Pro after 7-day trial | **Pro, immediately** | Partial | Not supported |
| Lossless audio (DTS-HD / TrueHD / E-AC3) | Yes | Pro (free tier can't play Dolby/DTS) | Yes | DTS-HD, AC3, E-AC3 |
| MKV / TS / AVI | Yes (FFmpeg layer) | Yes | Yes | Yes |
| Blu-ray folders (BDMV, ISO) | No | **Yes** | Yes | No |
| NAS: SMB / WebDAV / FTP-SFTP / Jellyfin / DLNA | Yes | Yes | Yes | Yes |
| Plex / Emby | Jellyfin only | **Yes** | Yes | No |
| Cloud drives (Drive/Dropbox/OneDrive) | No | **Yes** | Yes | Yes |
| Chromecast | No | **Yes** | Yes | Yes |
| AirPlay | Yes | Yes | Yes | Yes |
| PiP / chapters / multi-audio | Yes | Yes | Yes | Yes |
| Spatial audio | No (coming) | **Yes** | No | No |
| Platforms | iOS, iPadOS, **Android, Android TV** | Apple only | iOS + desktop | iOS, Android, Mac |
| Metadata | TMDB + optional TheTVDB | TMDB only | — | — |
| Anime4K upscaling | **Yes** (Android) | No | No | No |
| Open source | **Yes (GPLv3)** | No | **Yes** | No |
| Min iOS | **17** | 18 | 13 | 13 |

The honest summary: Infuse is the more complete Apple product, and I'm not
arguing otherwise. What DreamPlayer does differently is charge roughly half the
lifetime price, actually let a trial cover the HDR, run on Android too, and
support older iPads.

**Where I am deliberately not claiming a win:** nPlayer at $4.99 with no
subscription is excellent value and I've left it out of the "worth it" column on
purpose. If you want a one-and-done purchase and don't watch Dolby Vision, it's
hard to argue against.

---

## 0.8 The three posts

Each post below carries a **short, honest comparison**. The full table in 0.7 is
deliberately kept out of the post body — a big grid of competitor checkmarks
reads as a marketing brochure and is the fastest way to get accused of
astroturfing. It's there to paste into a comment when someone asks "how does it
compare to Infuse?", which they almost certainly will.

### 1. r/iosapps

**Title**

```
[Made for iOS] DreamPlayer — local video player with Dolby Vision, lossless audio and NAS support (7-day trial)
```

**Body**

```
I make this one, so take it with a grain of salt — but I built it to solve a
problem I kept hitting, and I think a few other people here have too.

This is a player for your OWN files. Nothing to sign up for, no streaming
service, no library sitting on someone else's servers.

What it does:

• Dolby Vision, HDR10, HDR10+ and HLG passthrough on hardware that supports
  it. Verified Dolby Vision on an iPad Pro M2. This was the main reason I
  built it — most iOS players either don't try, or quietly tone-map to SDR.

• Real lossless audio: DTS-HD, TrueHD, Dolby E-AC3 and 24-bit multichannel
  FLAC, with mid-playback track switching.

• MKV, TS and other containers AVPlayer won't open natively, via an FFmpeg
  demux layer — so a .mkv doesn't need converting first.

• Your NAS, several ways: SMB through the Files app's own "Connect to Server",
  plus WebDAV, FTP/SFTP, Jellyfin and DLNA. Works with "Open with" from any
  file manager.

• Sidecar subtitles just attach themselves — drop a .srt or .ass next to the
  video and it's picked up and auto-matched. PiP, chapters, multi-audio too.

Being straight about the cost, because I know it's the first question:

It's free to download and you get a 7-day trial of everything, including
Dolby Vision. After that, Dolby Vision / HDR playback and the extras
(playback speed, A-B loop, sleep timer, subtitle styling, online subtitle
search, download to device) are part of a subscription — ₹199/month, ₹1,499/year,
or ₹4,999 once. Browsing your files, playing SDR content, subtitles, PiP and
all the source types stay free.

For reference, Infuse locks Dolby Vision behind its Pro tier outright, so I'm
not claiming to be more generous — but I'm cheaper at every level than Infuse
is, and everything is unlocked for the first week so you can actually test the
HDR on your own files before deciding.

What it doesn't do:

• No streaming services. It's for files you already have.
• Dolby Vision output depends on your display, obviously.
• Can't fix it if the iPad's own hardware can't decode something.
• Requires iOS/iPadOS 17 or later.

How it stacks up, briefly, since I know Infuse is the name that comes up:

Infuse is the more complete Apple product and I'm not going to pretend
otherwise — it runs on Apple TV and Mac too, has Chromecast, iCloud/Trakt sync
across your devices, direct Plex, and handles Blu-ray folder formats I don't
touch. If you want one app for the entire Apple household, buy Infuse.

What DreamPlayer does differently:
• Roughly half the lifetime price — ₹4,999 (~$60) vs $99.99–$119.99
• The 7-day trial actually unlocks Dolby Vision, instead of locking it
  permanently behind Pro from the first play
• It also runs on Android and Android TV, and it's open source (GPLv3)

Worth being straight about two others: nPlayer is $4.99 once with no
subscription and is excellent value — if you don't watch Dolby Vision it's hard
to argue against. And VLC is genuinely free forever, but its HDR support is
partial.

https://apps.apple.com/in/app/dreamplayer-video-player/id6813066889

Happy to answer questions on the technical side — especially how the HDR path
works, which took a lot of digging.
```

---

## 2. r/AppStore

**Title**

```
New on the App Store: DreamPlayer — local video player with Dolby Vision, lossless audio, NAS support
```

**Body**

```
Just released DreamPlayer on the App Store. I'm the developer.

It's a video player for your own files, and it takes HDR and lossless audio
seriously on iOS.

• Dolby Vision, HDR10, HDR10+ and HLG passthrough on capable hardware
  (verified Dolby Vision on iPad Pro M2)
• DTS-HD, TrueHD, Dolby E-AC3 and 24-bit multichannel FLAC
• MKV / TS / WebM via an FFmpeg demux layer, so no remuxing needed
• NAS support: SMB through the Files app, plus WebDAV, FTP/SFTP, Jellyfin, DLNA
• Auto sidecar subtitles, PiP, chapters, multi-audio

iPhone and iPad, needs iOS 17+.

On price, since it's the obvious question: free to download, with a 7-day trial
that unlocks everything including Dolby Vision. After that Dolby Vision / HDR
and the extras (playback speed, A-B loop, sleep timer, subtitle styling, online
subtitle search, download to device) are subscription — ₹199/month, ₹1,499/year,
or ₹4,999 one-time. Browsing, SDR playback, subtitles, PiP and all source types
stay free. Infuse puts Dolby Vision behind Pro permanently, so this is a
deliberate difference rather than an accident — and while I'm at it, Infuse is
the more complete Apple product (Apple TV, Mac, Chromecast, iCloud sync,
Blu-ray folder support). DreamPlayer is iPhone/iPad, runs on iOS 17 rather than
18, is open source, and is roughly half Infuse's lifetime price.

https://apps.apple.com/in/app/dreamplayer-video-player/id6813066889

Feedback welcome, especially from devices I haven't tested against.
```

---

## 3. r/ipad

**Title**

```
iPad app I made: local video player with Dolby Vision passthrough, lossless audio and NAS support
```

**Body**

```
Built this because I wanted my iPad to play my own library properly —
including the Dolby Vision and DTS-HD files the built-in player handles badly
or not at all. Verified Dolby Vision and HDR10 passthrough on an iPad Pro M2.

iPad-relevant bits:

• Real HDR passthrough (DV, HDR10, HDR10+, HLG) rather than tone-mapped SDR
• DTS-HD / TrueHD / E-AC3 / 24-bit multichannel FLAC
• PiP, chapters, multi-audio, and sidecar subtitles that attach themselves
• NAS shares without a third-party server app — SMB through the Files app's
  "Connect to Server". WebDAV, FTP/SFTP, Jellyfin and DLNA also work.
• AirPlay to the TV when you want the big screen

It plays files you already own. No streaming services, no sign-up.

Free to download with a 7-day trial that unlocks everything, Dolby Vision
included. After the trial, Dolby Vision / HDR and the extras (speed, A-B loop,
sleep timer, subtitle styling, online subtitle search, download) are a
subscription — ₹199/mo, ₹1,499/yr, or ₹4,999 once. Everything else stays free.

Worth knowing on iPad specifically: Infuse is the more complete Apple product
(it covers Apple TV and Mac, has Chromecast, and syncs your library across
devices via iCloud). DreamPlayer is iPhone/iPad, works down to iOS 17, is open
source, is about half Infuse's lifetime price, and its trial actually includes
Dolby Vision. nPlayer at $4.99 once is also very good value if you don't need
DV.

https://apps.apple.com/in/app/dreamplayer-video-player/id6813066889

Would really like feedback from people with iPads I haven't been able to test on.
```

---

## Before you post — read this

**Timing.** No need to wait for anything. The paywall and the 7-day trial are
already live in the App Store build (0.4.8), and the drafts above describe
exactly that. 0.5.0 adds the Keychain mirror of the trial start time so the
trial survives deleting and reinstalling — the trial and the Dolby Vision / HDR
gate are unchanged, so the posts stay accurate either way.

**The claim that would have blown this up.** The earlier draft said Dolby
Vision was free forever. It is not — it's the paid tier. One person reading the
paywall and your post would have said so publicly. Every draft above now states
the trial up front, which is both honest and the better pitch: Infuse locks DV
behind Pro permanently, you unlock it for a week so people can test on their
own files.

**Don't post all three at once.** Same text to three subs reads as spam
coordination. Space them: 0.5.0 live → r/iosapps → a few days → r/ipad → then
r/AppStore.

**Check r/iosapps' self-promotion rule on the day you post.** Those change,
and some days require a flair or ban promotion outright.

**Work the comments.** Expect "is this just a wrapper?" — the FFmpeg demux
layer, the native HDR passthrough path, and the Keychain-persisted trial are
all real answers, and answering technical questions is what separates a
well-received dev post from a downvoted one.

**Don't compare yourself to Infuse by name in the title.** Mentioning it in the
body is fine and factual; making it the headline invites fanboyism and argument
you don't need.

**On the comparison specifically.** The single most important thing is that it
must include where Infuse wins — Apple TV, Mac, Chromecast, iCloud sync, Plex,
Blu-ray folders, spatial audio, 13 cloud providers, 33 formats. A comparison
that only lists your wins will get shredded in the comments by someone who has
actually used Infuse, and the whole post goes with it. Section 0.7 is written to
be defensible: every claim in it comes from the vendor's own App Store listing
as of 28 Sep 2026, and it says so. If a competitor ships something new, that
date is your liability — check it again before you post.

**Mentioning nPlayer costs you nothing and buys a lot of credibility.** Coming
out and saying "$4.99 with no subscription is excellent value and it's hard to
argue against" is the strongest signal in the whole post that you're not
writing marketing copy. It also heads off the most obvious counter-argument to
your pricing before anyone else makes it.

**Don't claim a format you haven't tested.** The format row says MKV/TS/AVI/WebM
because that's what the FFmpeg demux layer is verified against. Don't add
BDMV, ISO or VC1 to it to fill out the table — that's precisely the claim a
Firecore user will call out, and you'd lose the credibility the honest rows
bought you.
