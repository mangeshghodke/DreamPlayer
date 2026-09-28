# Reply to the r/AppStore commenter

One person, one comment — so this is a **single reply**, not a broadcast. Keep it
conversational. Long replies to a single engaged commenter read as
copy-pasted marketing, which is the exact thing that sub's posters are
suspected of.

Two rules for this specific reply:

- **Do not lead with a thank-you wall.** One short line, then substance.
- **Answer the Jellyfin question honestly, including the caveat.** They asked a
  precise technical question and clearly know the answer space. Hand-waving
  would lose them, and this is exactly the kind of commenter who replies again
  and helps you.

---

## The reply

```
Appreciate that, and the HDR note is the nicest thing anyone's said about the
screenshot — that shot does have a lot of fine texture in it.

On Jellyfin: it does request direct play. The stream URL is built with
`static=true` and the media source id, which is what tells Jellyfin to send
original bytes instead of remuxing. There's a transcode path in there
(`master.m3u8` with a codec cap) but it's only an explicit fallback, not the
default.

The honest caveat, and it's the right question to ask: I don't send a
PlaySessionId or a device profile. Infuse does a PlaybackInfo round-trip
declaring its real codec capabilities, so the server picks something it knows
the client can decode. DreamPlayer just asks for static and takes what comes
back. So for a clean DTS-HD or TrueHD source it direct-plays the original
bytes — but if the server decides transcoding is needed, the audio track is
whatever the server picked, not guaranteed lossless.

What I did do about that is make it visible rather than silent: if the
response is a server-side transcode, the player shows a red "Transcoding" chip
in the top bar, so you'd never quietly get AAC and assume that's what the file
had. That's the failure mode that actually annoyed me, so I made it loud.

Adding a proper device profile is on the list, and I'd rather say that than
pretend the current behaviour is more robust than it is.

And yeah — the openness was a deliberate choice. Nothing about the licensing
forced it; it's just that I'd rather people could check what the app is doing
with their files.
```

---

## Why it's shaped that way

**The caveat is volunteered, not buried.** They asked a specific question a
competent person would already suspect the answer to. Finding that out
themselves later would be much worse than hearing it now, and on a small sub
that one reply probably gets read by everyone else too.

**"That's the failure mode that actually annoyed me"** turns a limitation into
evidence you understand the problem. It's the most persuasive line in the reply
and it's cheap.

**"Adding a proper device profile is on the list"** converts a known gap into a
roadmap item. Don't over-promise a timeline — you have no Mac and can't test
Jellyfin direct-play locally, and a date you can't hit reads worse than no date.

**Don't mention Apple TV in the reply.** They raised it; you said so yourself.
Acknowledging it's the one place Infuse wins, once, and leaving it there is
enough. Re-litigating it sounds defensive.

---

## Follow-ups worth having ready

**"What does the red Transcoding chip actually detect?"**
It keys off the response: an HLS `master.m3u8`, or Jellyfin's `CI=1`
transcode flag, or `video/mp2t` on the DLNA path. It's a heuristic on the HTTP
response, not a PlaybackInfo query — which is exactly why it can say
"something was transcoded" but not reliably "no it wasn't".

**"Can I force direct play?"**
There's no toggle exposed. It always asks for `static=true`; the server can
still decline. Worth being straight that there's no user-facing control yet.

**"Does it work with Plex?"**
No, and it's a known gap. WebDAV / FTP / SMB / Jellyfin / DLNA are there.
Some Plex setups expose WebDAV, which will work, but there's no native Plex
integration. Don't imply otherwise.

**"Is the source really on GitHub?"**
Yes — GPLv3, and the NOTICE file lists every dependency and licence. If they
ask, point at the repo rather than describing it from memory.

---

## If they ask you to try something / report a bug

Say yes and mean it. This person found your post, engaged properly, asked a
real question and is being polite about a gap. A fast, honest answer to
"here's a bug I hit" is worth more than any amount of launch-day marketing.
