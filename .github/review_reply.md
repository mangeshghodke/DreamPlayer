**Reply to App Review — Build 0.4.8+13**

Thank you for the review. We have addressed both issues:

---

**1. Terms of Use (EULA) link**

We have added a functional Terms of Use link inside the app at **Settings > About > Terms of Use**, which opens our EULA hosted at:

https://mangeshghodke.github.io/DreamPlayer/terms.html

The same link also appears in the in-app paywall sheet (bottom of the subscription screen) alongside the Privacy Policy. Both links are visible before any purchase is made.

Additionally, we will add this URL to the App Store Connect app description before resubmission.

---

**2. Demo account — clarification**

DreamPlayer does **not** have its own user accounts or login system. The app is a local/network video player. All login features in the app are **optional connections to the user's own private services**:

- **Jellyfin / Emby**: Connects to the user's self-hosted media server (like Plex). No account is created in our app — the user enters their own server URL and credentials. This is entirely optional; the app plays local files without any login.
- **WebDAV / SMB**: Connects to the user's own NAS or network drive. Optional — local file playback requires no login.
- **OpenSubtitles**: Optional subtitle search service. Works without login (anonymous, rate-limited) or with a free OpenSubtitles.org account. Not required for any core functionality.

The app's core functionality — playing local video files with subtitles, Dolby Vision, and HDR — works **completely without any login**. No demo account is needed because there is no app-level account system.

We confirm: **the app does not include a login or account-based feature** in the traditional sense. All remote connections are to user-owned infrastructure and are entirely optional.
