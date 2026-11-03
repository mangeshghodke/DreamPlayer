# dreamplayer-crash-report (Cloudflare Worker)

Receives DreamPlayer crash reports (multipart/form-data POST with fields
`message`, `platform`, `appVersion` and one or more `logs` file parts) and
emails them to the support inbox via the Send Email binding.

## Deploy

```bash
cd cloudflare/crash-report
npm install
export CLOUDFLARE_API_TOKEN=<token>   # never commit this
npx wrangler secret put CRASH_REPORT_SECRET   # same value as the app's
                                              # --dart-define=CRASH_REPORT_SECRET
npx wrangler deploy
```

Live URL: `https://dreamplayer-crash-report.ghodke-mangesh2.workers.dev`

The `to` address must be a verified Email Routing destination on
softbuydeals.in (the Gmail behind the forward rule). `from` must be an
address on the zone (Email Routing enabled). The worker checks
`Authorization: Bearer $CRASH_REPORT_SECRET` when the secret is set.
