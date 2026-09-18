# DreamPlayer Privacy Policy

**Effective Date:** September 18, 2026

DreamPlayer does not collect, store, or share your personal data.

### Data Collection
- **No analytics, no tracking, no ads.**
- Video playback is local or from your own NAS (SMB / WebDAV / Jellyfin / FTP / DLNA). Files never leave your device.
- Library folders, resume positions, watched marks, and settings are stored locally on-device (SharedPreferences / UserDefaults / Keychain/Keystore for passwords).

### Third-Party Services (only when you use them)
- **The Movie Database (TMDB):** When you enter a TMDB API key, the app queries `api.themoviedb.org` for posters/backdrops/cast. Queries contain only the title/year you search — no device IDs. See https://www.themoviedb.org/privacy-policy
- **OpenSubtitles:** Subtitle search/download via `api.opensubtitles.com` (if you enable it). See https://www.opensubtitles.com/privacy_policy
- **SIMKL:** Watch-state sync via `api.simkl.com` (if you sign in). See https://simkl.com/about/privacy/
- **In-App Purchases (iOS only):** Purchases are processed by Apple via StoreKit 2. DreamPlayer receives only an entitlement flag — no payment data. See https://www.apple.com/legal/privacy/

No data is sold to third parties.

### Contact
Questions? Open an issue: https://github.com/mangeshghodke/DreamPlayer/issues

**Developer:** Mangesh Ghodke
