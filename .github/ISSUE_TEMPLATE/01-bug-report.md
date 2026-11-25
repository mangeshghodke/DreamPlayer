---
name: Bug report
about: Something is not working as expected
title: '[Bug]: '
labels: bug
---

**Before filing:** please check the existing issues (open and closed) - someone may have reported it already. If the app crashed, use **Settings → "App crashed?"** in the app first: it attaches the crash log automatically (`logcat_dump.log` on Android, `app_debug.log` / `smb_debug.log` / `iap_debug.log` on iOS) and can submit the report for you.

### Description
A clear, short description of the bug.

### Steps to reproduce
1. Go to …
2. Open …
3. Play / tap …
4. See error

### Expected behavior
What you expected to happen.

### Actual behavior
What actually happened (error text, wrong colors, no audio, crash, …).

### Environment
- App version + build: Settings → About (e.g. `0.5.8+15`, TestFlight build 15, or the GitHub release tag)
- Platform: Android (sideload APK / Fire TV) or iOS/iPadOS (TestFlight)
- Device: e.g. OnePlus 12R, Android 16 / iPad Pro M2, iPadOS 26
- Video source: internal storage, SMB, WebDAV, FTP/SFTP, Jellyfin, DLNA/UPnP, Play URL, "Open with", WiFi transfer

### Media file details (if playback-related)
- Container/extension: `.mkv`, `.mp4`, …
- Video codec / HDR: H.264, HEVC Main10, Dolby Vision profile, HDR10/HDR10+/HLG, SDR
- Audio codec: AAC, E-AC3 (+Atmos), AC3, DTS, DTS-HD, TrueHD, FLAC, …
- Engine used: Media3 or "Play with MPV" (visible in the ⋮ → Video info sheet)
- Playback settings that matter: Hardware SDR tone-mapping on/off, audio passthrough, default engine

### Logs & screenshots
- If the app crashed or froze: attach the files from the in-app **"App crashed?"** report form, or from Files → On My iPad → DreamPlayer (`app_debug.log`, `smb_debug.log`) / Android `logcat_dump.log`.
- Screenshots or a screen recording of the problem (the ⋮ → Video info sheet is useful for playback bugs).

### Additional context
Anything else - network setup (NAS, Wi-Fi), recent changes, whether it worked in an earlier version.
