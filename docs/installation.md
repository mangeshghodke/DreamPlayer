# Download & installation


Full feature list, codec tables, screenshots and FAQs: **[dreamplayer.isroot.in](https://dreamplayer.isroot.in/)**

## iOS / iPadOS — [App Store](https://apps.apple.com/us/app/dreamplayer-video-player/id6813066889)

DreamPlayer is approved and **live on the App Store** for iPhone and iPad (requires iOS / iPadOS 18.0+).

**[Download on the App Store →](https://apps.apple.com/us/app/dreamplayer-video-player/id6813066889)**

## Android

Prebuilt **Android** binaries are on the [Releases](https://github.com/mangeshghodke/DreamPlayer/releases) page.

- **Android** — universal APK + per-architecture APKs (arm64, armv7, x86_64)

### Get updates automatically with Obtainium

<a href="https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.dreamplayer.app%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fmangeshghodke%252FDreamPlayer%2522%252C%2522author%2522%253A%2522mangeshghodke%2522%252C%2522name%2522%253A%2522DreamPlayer%2522%257D"><img src="https://dreamplayer.isroot.in/assets/img/badge-obtainium.png" width="161" height="48" alt="Get it on Obtainium"></a>

[**Obtainium**](https://obtainium.imranr.dev/) installs and updates apps straight from their GitHub Releases, so you get each DreamPlayer build without watching this page. The link above adds DreamPlayer to Obtainium in one tap; if Obtainium isn't installed yet, it offers to get it first.

- Updates are **signature-checked**: Obtainium only installs a build signed with the same key as the one already on your device.
- **Stay on the same APK flavour.** The arm64/armv7/x86_64 builds carry a higher Android `versionCode` than the universal build, so a phone that installed a per-architecture APK cannot later "update" to the universal one — Android reads that as a downgrade. Pick one and keep it.
- Builds before **0.5.2** were signed with a throwaway CI key and must be uninstalled once. From 0.5.2 on, the key is permanent and every update installs over the previous one.

No `.ipa` is published on GitHub Releases. Apple only allows iOS distribution via the **App Store**, **TestFlight**, or **Ad Hoc** (DPLA 7.6 / 3.2(g)). Signed iOS builds are produced by the separate [`ios.yml`](https://github.com/mangeshghodke/DreamPlayer/actions/workflows/ios.yml) workflow, uploaded to **TestFlight**, and released publicly on the App Store.
