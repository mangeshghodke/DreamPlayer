# Spatial audio

## On Android

DreamPlayer surfaces the **system Spatializer** (Android 13+,
`AudioManager.getSpatializer()`) as a teal **"Spatial"** chip in the
player top bar. When the chip is on, your phone is virtualizing the
surround mix for your output device (stereo headphones, phone speaker,
or a USB DAC). The Spatializer is implemented by the OEM, so the
quality / available modes vary by device. The chip turns on only when
the system reports:

1. The Spatializer is available on this device.
2. The current routing (headphones, USB, etc.) supports spatialization.
3. The current output is decoded multichannel PCM (typically 5.1/7.1); the
   source codec itself is not the deciding factor.

Both Media3 and MPV use the same Android phone setting. MPV decodes DTS/DTS-HD,
TrueHD, E-AC3, AC3, FLAC, AAC, and similar tracks to PCM through
`AudioTrack`; the Spatial chip is shown only when that output remains eligible
for the active route. Stereo/downmixed output and encoded bitstream passthrough
are not platform-spatialized.

To enable spatial audio in DreamPlayer:

1. **Connect headphones or a USB DAC.** Phone speakers don't get
   spatialized on most devices.
2. **Open the file you want to play.** A multichannel track is required
   — a stereo `.aac` won't engage the Spatializer.
3. **Enable system spatial audio:**
   - **OnePlus / OPPO** — Settings → Sound & vibration → Spatial Audio
     → enable, then choose "Music & Video". On ColorOS 13+ this is
     under Settings → Sound & vibration → Dolby Atmos / OPlus Audio.
   - **Samsung (One UI 6+)** — Settings → Sounds and vibration → Sound
     quality and effects → Dolby Atmos for games / movies, **and**
     "Adapt Sound" / "Dolby Atmos for headphones" if you're on the
     built-in speakers. The Spatializer only reports available when
     "Dolby Atmos" is on.
   - **Xiaomi (MIUI 14+)** — Settings → Sound & vibration → Sound
     effects → Immersive Sound / Dolby Atmos. On some MIUI builds the
     option is under "Audio tuner" → "Apply sound effects to media".
   - **Pixel (Android 14+)** — Settings → Sound & vibration → Spatial
     audio. The Pixel implementation is limited; some Pixels only
     spatialize on specific Bluetooth codecs (LDAC / aptX Adaptive).
   - **Nothing OS / Motorola / ASUS ZenUI** — most ship with the
     Spatializer disabled. Install **Dirac Audio** / **Dolby Access** /
     your OEM's audio app and enable spatialization from there; the
     system Spatializer reports available once the OEM app is active.
4. **Look for the "Spatial" chip in the player top bar.** When the
   Spatializer is on for the current track the chip turns teal. Tap
   the **ⓘ** button next to the title — the "Spatial audio" row reads
   "On" with the routing info.

On iOS the same idea ships as a premium opt-in — see *Spatial Audio on iOS*
below.

## On iOS

DreamPlayer enables **Apple's built-in AVPlayer spatialization** for
multichannel soundtracks on the native AVPlayer path (Apple containers:
HEVC / progressive H.264 in MP4/MOV). The feature is a **premium unlock**
(Settings → Audio → **Spatial audio** — opt-in, paywall-gated, off by
default). When enabled:

- **Native AVPlayer path** (HEVC, progressive H.264 in MP4/MOV):
  `AVPlayerItem.allowedAudioSpatializationFormats = .multichannel`
  opts the item into system binaural HRTF virtualization. The system
  decides whether to apply it (Control Center → AirPods settings; head-
  tracking only on AirPods Pro/Max with compatible iOS version).
- **Software (FFmpeg) path** (AV1/VP9/VP8/MPEG-2/VC-1, interlaced
  H.264, MKV/TS/AVI/WebM containers): the engine's internal renderer
  opts into `.multichannel`; the host **cannot** opt it out without
  downmixing the session to stereo. A free user on a spatializing route
  therefore gets stereo instead of 5.1/7.1 on the software path — the
  trade-off is documented. The native path is exact.
- The **Settings toggle** gates the opt-in: turning it on for a free user
  opens the paywall; an entitled user (subscriber or in the 7-day trial)
  gets it immediately. The toggle reads `dreamplayer.spatialAudio` from
  shared_preferences (iOS maps it to UserDefaults) so it persists across
  restarts.
- A **teal "Spatial" chip** appears in the player top bar when the opt-in
  is on **and** the route is actually spatializing — matching Android's
  chip behavior.
- The **Bass Boost** row (Settings → Audio → Bass Boost) appears
  automatically while the Spatial chip is on, to compensate for HRTF
  low-end thinning — same rule as Android.
- The **Restore Purchases** button re-syncs the entitlement; if the
  subscription lapses the toggle reverts to off on the next app launch.
