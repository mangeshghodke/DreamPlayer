/// SIMKL API client credentials (OAuth).
///
/// Supplied at build time via `--dart-define=SIMKL_CLIENT_ID=...`
/// and optional `--dart-define=SIMKL_CLIENT_SECRET=...`
/// (see `.env.example`). Empty by default - the SIMKL section in
/// Settings is hidden until a client id is configured. Never commit
/// real credentials. Get yours at https://simkl.com/settings/developer/
const String simklClientId = String.fromEnvironment('SIMKL_CLIENT_ID');
const String simklClientSecret = String.fromEnvironment('SIMKL_CLIENT_SECRET');
