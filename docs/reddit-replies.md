# Reddit comment replies — prepared answers

Short by design. The most common mistake with these is writing a defence of the
app; what actually works is conceding the point, then giving the *one* concrete
reason their use case differs. Three or four lines beats a paragraph every time.

**Rules I'm following in all of these:** concede the competitor's strength
first, one specific reason after, no disparagement, no "better value"
salesy phrasing, and re-state that I'm the developer without belabouring it.

---

## "But why not just use Infuse?"

The most likely question. Infuse is genuinely excellent, so lead with that.

```
Infuse is a great app and I mean that — it's the better choice if you want
one app across Apple TV and Mac, Chromecast, and iCloud sync of your library.

The reason I built this separately: Infuse locks Dolby Vision and Dolby/DTS
audio behind Pro from the very first play. I wanted to be able to test Dolby
Vision on my own rips before deciding anything, so the 7-day trial here
actually unlocks it. Everything else — playing your files, subtitles, all the
NAS types — works without paying either way.

Also worth noting it's GPLv3 and runs on Android too, but that's secondary.
```

Short version, if the thread is moving fast:

```
Fair question. Infuse is better if you want the whole Apple ecosystem covered.
The difference is the trial — Infuse gates Dolby Vision and DTS behind Pro
permanently, here the 7-day trial actually unlocks them so you can test on
your own files first. Half the lifetime price too (₹4,999 vs $99.99).
```

---

## "Isn't this just a VLC wrapper / a skin for the OS player?"

Second most common, and it deserves a real technical answer.

```
It's native, not a wrapper. The iOS engine is AVPlayer plus an FFmpeg demux
layer for the containers AVPlayer won't open natively — MKV, TS, AVI, WebM —
which is why an .mkv doesn't need remuxing first. The Dolby Vision / HDR
passthrough runs through the real system path rather than being tone-mapped to
SDR, which is the thing most players get wrong on iOS.

The Android side is ExoPlayer/Media3 in a native platform view. No Flutter
textures anywhere, deliberately — Flutter textures have no HDR path on any
platform, so video written through one gets flattened to SDR before the panel
ever sees it. That was the main thing I had to get right.
```

If they follow up with "so is the source available":

```
Yeah, GPLv3 — the notice file lists every dependency and its licence. The
Android source is all of it; nothing is closed off.
```

---

## "Another app shilling itself on r/iosapps"

Hostile framing. Don't engage with the accusation — just answer the implicit
question.

```
Fair, this is a self-promo post and I'm the developer, so I get why that's
annoying. Happy for it to be removed if the mods disagree.

Genuinely curious about the category though — what's the thing you use
Infuse/VLC for that would have made you close this one out? I'd rather fix
it than argue about it.
```

That last line matters. It converts a hostile comment into a source of
feedback, and mods read it as good faith.

---

## "It says Dolby Vision is free but I got a paywall"

The one to get right. Never deny it, never over-explain.

```
That's a real bug in my post, thanks for flagging it — Dolby Vision / HDR is
part of the paid tier after the 7-day trial, not free. I've fixed the wording.

To be clear about what IS free permanently: browsing everything, playback of
non-HDR video, subtitles, PiP, chapters, audio tracks and all the source types
(SMB, WebDAV, FTP, Jellyfin, DLNA). The paid tier is Dolby Vision / HDR plus
playback speed, A-B loop, sleep timer, subtitle styling, online subtitle search
and download.
```

If they caught the old draft, own it immediately and without hedging. A single
"that's my mistake, fixed" does more for your credibility than any amount of
careful marketing.

---

## "How's this different from nPlayer for $4.99?"

They found the real weakness. Concede it.

```
Honestly nPlayer is great value — $4.99 once with no subscription is hard to
argue against.

The differences: nPlayer doesn't do Dolby Vision, DreamPlayer is GPLv3, and it
also runs on Android and Android TV. And here the trial includes Dolby Vision
rather than locking it behind a permanent upgrade.
```

---

## Technical questions worth answering well

These are where the app's reputation gets built. Answer them properly.

**"How do you do DV passthrough on iOS?"**
```
It's the system path, not a re-implementation. AVPlayer plus an FFmpeg demux
layer for the containers it won't open natively. The key bit is the file has to
reach AVPlayer intact — no re-encode, no transcode — or the RPU metadata is
lost and it falls back to plain HDR10. MKV in particular usually gets demuxed
straight to the player.
```

**"Does it work without an account / does it phone home?"**
```
No account, no analytics, no ads. It talks to your NAS and to whichever
metadata API key you enter yourself (TMDB or TheTVDB). Nothing else leaves
the device.
```

**"Why no Plex?"**
```
Good question and I know it's a gap. WebDAV, FTP/SFTP, SMB, Jellyfin and DLNA
are all there, and a lot of Plex setups expose one of those — but yeah, native
Plex support is missing and it's on the list.
```

**"iOS 18 only?"** (they'll assume it because of Infuse)
```
iOS 17 and up, so older iPads and iPhones are fine. (Infuse is 18+.)
```

---

## Tone reminders

- **Concede first, always.** "Infuse is a great app" costs you nothing and
  makes everything after it credible.
- **One reason, not five.** A list of differentiators reads as a spec sheet and
  nobody believes it.
- **Don't say "better value" or "cheaper" in a reply.** It sounds like sales.
  Price is fine to state as a fact in the post, awkward in an argument.
- **Never disparage.** Someone who loves Infuse isn't wrong to. Being gracious
  to a fan of a competitor is the single highest-ROI thing you can do here.
- **If someone says your app is bad, ask what broke.** It's usually a real bug
  you didn't know about, and it costs nothing to find out.
- **Don't argue with mods.** If a post gets removed, thank them and ask about
  the rule. Arguing with moderators on r/iosapps is how accounts get flagged.
