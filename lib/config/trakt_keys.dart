/// Trakt API client credentials (OAuth).
///
/// Supplied at build time via `--dart-define=TRAKT_CLIENT_ID=...`
/// and optional `--dart-define=TRAKT_CLIENT_SECRET=...`
/// (see `.env.example`). Empty by default - the Trakt section in
/// Settings is hidden until a client id is configured. Never commit
/// real credentials. Get yours at https://trakt.tv/oauth/applications/new
///
/// Trakt's Standard API is free (no per-user fee, no revenue share), so the
/// integration below is always free to use once a client is configured.
const String traktClientId = String.fromEnvironment('TRAKT_CLIENT_ID');
const String traktClientSecret = String.fromEnvironment('TRAKT_CLIENT_SECRET');
