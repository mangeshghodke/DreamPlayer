# App Store Connect — In-App Purchase Submissions

Paste-ready text for the three purchase products
(App Store Connect → your app → *In-App Purchases* → a product → its
localization).

Why this file: spatial audio became a premium feature in 0.5.5 and the
purchase descriptions in App Store Connect had drifted from what the app
claims. Keep this file as the source of truth and re-paste after any gated
feature changes, the same way `ASC_CHANGELOG.md` is kept for What's New.

Rules the 0.5.1 metadata rejection taught (In-App Purchase text is metadata):

- **Other platforms are forbidden.** No Android, no Linux, no player names.
  These are iPhone/iPad screens talking to an iPhone/iPad reviewer.
- Say what the purchase unlocks, in user terms. Vague "and more" is a
  rejection risk.
- Keep descriptions ≤ 100 characters (the historical IAP description cap) so
  they never trip a field limit even if it has since been raised.
- No superlatives, no prices (prices are shown by the purchase sheet and vary
  by territory).

Character counts sit beside each block so an edit can be re-checked at a
glance.

## The three products

| Product ID | Type | Symbol | Name (chars/30) | Description (chars/100) |
|---|---|---|---|---|
| `dp_premium_monthly_2026` | auto-renewable subscription | ₹199 | DreamPlayer Premium Monthly (27) | Unlocks Dolby Vision & HDR… one month. (93) |
| `dp_premium_yearly_2026` | auto-renewable subscription | ₹1,499 | DreamPlayer Premium Yearly (26) | Unlocks Dolby Vision & HDR… one year. (92) |
| `dp_premium_lifetime_2026` | non-consumable | ₹4,999 | DreamPlayer Premium Lifetime (28) | One-time purchase. Unlocks… and speed. (98) |

The product IDs and prices are already live — leave them alone; only the
localization text below is being replaced.

### `dp_premium_monthly_2026` — Monthly

- **Display Name** (27/30):

  DreamPlayer Premium Monthly

- **Description** (93/100):

  Unlocks Dolby Vision & HDR playback, spatial audio, subtitle styling and speed for one month.

### `dp_premium_yearly_2026` — Yearly

- **Display Name** (26/30):

  DreamPlayer Premium Yearly

- **Description** (92/100):

  Unlocks Dolby Vision & HDR playback, spatial audio, subtitle styling and speed for one year.

### `dp_premium_lifetime_2026` — Lifetime

- **Display Name** (28/30):

  DreamPlayer Premium Lifetime

- **Description** (98/100):

  One-time purchase. Unlocks Dolby Vision & HDR playback, spatial audio, subtitle styling and speed.

## Subscription group (both subscriptions)

App Store Connect → *Subscriptions* → the group → its localization. This is
what the purchase sheet shows under the plan picker.

- **Group Display Name** (19/30):

  DreamPlayer Premium

- **Group Description** (166/170):

  Dolby Vision and HDR playback, spatial audio on AirPods, subtitle styling, playback speed, A-B repeat, a sleep timer and downloads — all premium features in one plan.

## Review notes (paste into the app's "Notes", or each product's)

> DreamPlayer is a video player. Every premium feature is unlocked by any of
> the three in-app purchases (monthly, yearly, lifetime).
>
> To test a gated feature without purchasing: all three products can be
> bought with the sandbox account, or start the free trial from the first-run
> screen ("Start Free Trial") — the trial unlocks everything for 7 days and
> requires no payment.
>
> What is gated and where:
> - Dolby Vision / HDR10 / HDR10+ / HLG playback — playing an HDR video.
> - Spatial audio — Settings → Audio → Spatial audio (turn it on).
> - Subtitle styling — the CC button in the player → Subtitle settings.
> - Playback speed, A-B loop, sleep timer — the player's bottom-bar menu.
> - Download to device — the player's menu or a details screen.
> - OpenSubtitles online search — the CC button → Search online subtitles.
>
> Every paying state starts with Restore Purchases on the purchase sheet, so
> an owned entitlement restores without paying again. Cancelling a
> subscription stops renewal — access continues until the end of the paid
> period (our Terms of Use say the same).

## What the app shows (for consistency)

The paywall sheet's "What's included" popover (the ⓘ button) and the
first-run trial screen list exactly:

- Dolby Vision & HDR10+ playback
- HDR10 & HLG passthrough
- Spatial audio (AirPods Pro & compatible devices) — trial screen:
  "Spatial audio (AirPods Pro)"
- Subtitle styling (size, color, outline, delay)
- Playback speed control (0.25×–2×)
- A-B loop
- Sleep timer
- Download to device
- OpenSubtitles online search
- Priority updates & support

If a future feature is added to these lists, add it to the paste-ready
descriptions above in the same commit — a purchase description that promises
less than the app's paywall claims is an App Review inconsistency.
