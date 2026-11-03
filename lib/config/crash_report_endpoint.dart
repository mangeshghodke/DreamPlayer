/// Crash-report upload endpoint — a Cloudflare Worker (or any HTTPS server)
/// that accepts a multipart/form-data POST and forwards the logs, e.g. to
/// the support inbox.
///
/// Resolution: the `--dart-define=CRASH_REPORT_ENDPOINT=...` value, else ''.
/// Empty means "not configured": the "App crashed?" note then falls back to
/// the platform share sheet (mailto: cannot carry attachments).
const String crashReportEndpoint =
    String.fromEnvironment('CRASH_REPORT_ENDPOINT');
