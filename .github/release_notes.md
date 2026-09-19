## Download & install

### Android

Pick the APK for your device and allow "Install unknown apps" when prompted:

| File | Best for |
|---|---|
| `DreamPlayer-<version>-arm64-v8a.apk` | 64-bit ARM phones (most modern Android devices) |
| `DreamPlayer-<version>-armeabi-v7a.apk` | 32-bit ARM phones (older devices) |
| `DreamPlayer-<version>-x86_64.apk` | 64-bit Intel/AMD devices (emulators, some tablets) |
| `DreamPlayer-<version>-universal.apk` | **Universal** — all architectures in one file, installs everywhere |

Not sure which to pick? Grab the **Universal** APK.

## Versioning

App version follows **semver**, bumped per release (current release: **0.4.7**).

## Playing videos from your NAS / SMB share

DreamPlayer plays NAS files through the Files app's built-in SMB support and "Open with"

- **iPhone/iPad:** Files → **⋯ → Connect to Server** → enter `smb://<address>` → browse to a video → long-press → **Share → Open in "DreamPlayer"**. Prefer a folder? Bookmark it once: home **+** → **Add folder to library** → your NAS folder.
- **Android:** CX Explorer → **Open with → DreamPlayer** (streams over CX's local HTTP proxy).

Full walkthrough: **[SMB / NAS playback tutorial](docs/tutorials/play-smb-nas-videos.md)**.
