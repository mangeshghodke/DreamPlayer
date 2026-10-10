## Download & install

### ⚠️ Updating from 0.5.1 or earlier — one-time reinstall required

DreamPlayer **0.5.2 and later install straight over your existing copy.** No
uninstall, and your settings, library and continue-watching positions are kept.

But if your current copy is **0.5.1 or older**, you have to uninstall once
first. Those releases were signed with an automatically generated debug key that
existed only on the build server and no longer exists, so Android cannot accept a
differently-signed update — it reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
There is no way around it for those specific versions.

What to do, once:

1. Note anything you want to keep — your server logins and library folders are
   stored on the device and will be removed with the app.
2. Uninstall DreamPlayer.
3. Install the new APK.

**That is the last time.** From 0.5.2 onward every release is signed with
DreamPlayer's own permanent certificate, and from now on you just install the new
APK over the old one.

### Already on 0.5.2 or later? Just install over it

**Download the same file you downloaded last time** — same architecture, same
name. Tap the new `.apk` over the installed one and Android updates it in place.

| You installed | Download |
|---|---|
| `…-arm64-v8a.apk` | `…-arm64-v8a.apk` again |
| `…-armeabi-v7a.apk` | `…-armeabi-v7a.apk` again |
| `…-x86_64.apk` | `…-x86_64.apk` again |
| `…-universal.apk` | `…-universal.apk` — or any split build, both work |

**Why the same one matters.** Android identifies builds by application id
(`com.dreamplayer.app`) *and* version code, and the per-architecture APKs carry
much higher version codes than the universal one. Switching from an
architecture-specific build to universal (or back) therefore looks like a
downgrade and is rejected with `INSTALL_FAILED_VERSION_DOWNGRADE`. That is not
a broken update — it just means the wrong file.

### First time installing

Pick the APK for your device and allow "Install unknown apps" when prompted:

| File | Best for |
|---|---|
| `DreamPlayer-<version>-arm64-v8a.apk` | 64-bit ARM phones (most modern Android devices) |
| `DreamPlayer-<version>-armeabi-v7a.apk` | 32-bit ARM phones (older devices) |
| `DreamPlayer-<version>-x86_64.apk` | 64-bit Intel/AMD devices (emulators, some tablets) |
| `DreamPlayer-<version>-universal.apk` | **Universal** — all architectures in one file |

Not sure which to pick? Grab the **Universal** APK. For a fresh install it is
the most flexible choice: you can later move to an architecture-specific build
if you want the smaller file.

## Versioning

App version follows **semver**, bumped per release. Android's internal version
code is separate and always increases, which is what lets an update install over
an existing copy.

## Playing videos from your NAS / SMB share

DreamPlayer plays NAS files through the Files app's built-in SMB support and "Open with"

- **iPhone/iPad:** Files → **⋯ → Connect to Server** → enter `smb://<address>` → browse to a video → long-press → **Share → Open in "DreamPlayer"**. Prefer a folder? Bookmark it once: home **+** → **Add folder to library** → your NAS folder.
- **Android:** CX Explorer → **Open with → DreamPlayer** (streams over CX's local HTTP proxy).

Full walkthrough: **[SMB / NAS playback tutorial](docs/tutorials/play-smb-nas-videos.md)**.
