# Love Boo Expo — Project Context

> **Keep this file current.** After any change to logic, data model, files or infra, update the relevant section and the "Last updated" line. Read this first instead of re-reading every file.

Last updated: 2026-10-18

## What this is
Registration + spin-to-win for the Love Boo booth at Dubai Baby Expo 2026. Plain static site (HTML/CSS/JS, no framework, no build step), deployed on Vercel from GitHub `main` (auto-deploy on push). Backend: Supabase (DB, Auth, Storage, Realtime). Marketing list: Klaviyo (fed by CSV export from admin, not live).

## Files
| File | Purpose |
|---|---|
| `index.html` | The entire guest flow: landing (wheel preview + "Sign Up & Spin") → form → wheel → prize reveal. All logic is inline `<script>`. |
| `admin.html` | Login-gated dashboard (Alpine + DaisyUI): **Registrations** tab (search, CSV export, realtime) and **Wheel Prizes** tab (add/edit/delete, image upload, quantity, on/off toggle). |
| `wheel.html` | Retired. Redirects to `/`. |
| `supabase-config.js` | Supabase URL + anon key (public; protected by RLS). Never put the service-role key here. |
| `vendor/` | Self-hosted third-party JS/CSS used by index.html. |
| `sw.js` | Service worker: network-first shell, cache-first `/vendor/`, offline fallback to `/` (`CACHE_VERSION` now v13 — bump it when shipping shell changes). Never touches POSTs / Supabase calls. |
| `manifest.json`, `icons/`, `favicon.png` | PWA bits. |
| `vercel.json` | Clean URLs, cache headers, noindex on admin/wheel. |
| `supabase/klaviyo-gated-admin.sql` | Migration (untracked in git as of this writing): adds `registrations.klaviyo_synced` and an admin UPDATE policy on `prizes`. |

Note: the `prizes` table, `claim_prize` RPC and other RLS policies were created directly in Supabase and are **not** in the repo's SQL files.

## Prize logic (index.html, `doSpin()`)
1. **Wheel contents** — `fetchAvailablePrizes()` loads `prizes` where `active = true`, ordered by `sort_order`, then drops any with `quantity` set and `given_count >= quantity` (sold out). Unlimited prizes have `quantity = NULL`.
2. **Segments** — each remaining prize gets one equal-size slice, plus exactly **one "Try Again" slice** at the end. If no prizes are configured, a single "Mystery Gift" placeholder (no id, unlimited) is used. Prize names are hidden on the wheel (only photos); names appear on the reveal screen.
3. **Result is a stock-weighted random pick** — `pickWeightedIndex()`, done **client-side**. Slices are drawn equal-sized, but a prize's chance is proportional to its *remaining* stock (`quantity - given_count`), so high-quantity prizes come up most and odds shift automatically as stock drops. Unlimited prizes (`quantity` NULL) weigh as much as the largest limited stock. "Try Again" always gets `TRY_AGAIN_SHARE` (0.25) of the total probability per spin.
   - **Mystery Gift** = a normal prize row in admin with `quantity = 10` (total for the 3-day event). Its small stock makes it rare; it is not paced per day, so it could go early.
4. **Try Again** — landing on it on spin #1 gives one free re-spin ("So close! One more spin..."). Landing on it on spin #2 = no prize. So max 2 spins per registration. `spinCount` resets on each form submit.
5. **Claiming** — a real prize is claimed with the Supabase RPC `claim_prize(target_id)` (security definer), which atomically increments `given_count` only if stock remains. If it returns false (someone took the last unit at the same moment) or errors, the guest gets a **no-prize** outcome instead.
6. **Mystery Gift placeholder / no-id segments** skip the claim and are awarded directly.
7. The animation lands on the chosen slice (with a small random jitter inside the slice); the outcome is decided *before* the spin animation starts.

## Guest flow & data writes
- Form fields: first name, last name (optional), email, phone + country code (optional), parent Yes/No, terms checkbox (also the marketing consent). Duplicates are intentionally allowed (no dedup — user's decision).
- **Klaviyo is NOT called from the guest page anymore.** Everyone is stored in Supabase only; the list is exported from admin and imported into Klaviyo later.
- Nothing is sent until the spin is resolved. Then `recordRegistration()` → `queueRegistration(row)` (**outbox pattern**):
  1. Written to the outbox (memory + localStorage `lb_outbox_v2`) *before* any network call and before the reveal; the guest sees the result immediately.
  2. Sent to Supabase in the background (10s timeout; 4 quick attempts, then every 15s, on `online`, and when the tab becomes visible) until accepted. Old Klaviyo-era queues (`lb_expo_pending_queue`, `lb_expo_supabase_pending_queue`) are migrated into plain Supabase rows on load.
  3. Each row has a `client_id` (uuid) → upsert with ignoreDuplicates, so retries never duplicate (falls back to plain insert until `supabase/reliability.sql` is applied).
- Stored in `registrations`: name, email, phone, is_parent, source, `prize` (null if none), UTM fields, `client_id`, `created_at`. `klaviyo_synced` is legacy/unused.
- Validation: visible inline error (`#lbFormError`) for name / email format / terms; email lowercased; phone normalised to E.164 (dial code not doubled).
- Vendor libs (supabase, tailwind browser, daisyUI, anime, confetti, alpine) are self-hosted in `vendor/` and cached by the SW.

## Klaviyo export (admin → "Export for Klaviyo")
- Modal with scope: All / New since last export (remembered in the admin browser's localStorage `lb_last_klaviyo_export`) / Today. Everyone is included regardless of prize.
- Format follows Klaviyo's own template (`List Import Template 2026 10 18 0330.csv` in the repo root): `email, phone number, external id (client_id), Email Marketing Consent=SUBSCRIBE + timestamp, SMS Marketing Consent=SUBSCRIBE + timestamp (only if phone), firstname, lastname, Custom Property (Prize / Is Parent / Event / Source / UTM Source / UTM Medium / UTM Campaign)`. Timestamp = registration time, UTC `YYYY-MM-DD HH:mm:ss`. UTF-8 BOM, CSV-formula-injection guard on text cells (not email/phone/id).
- Import in Klaviyo: Lists & Segments → list → Add profiles → Import from CSV; map columns; confirm the consent step. Plain "Export CSV" still exists for a general dump.

## Supabase
- Tables: `registrations`, `prizes` (`id, name, image_url, image_path, quantity, given_count, active, sort_order, created_at`). Storage bucket: `prize-images` (public).
- RLS: anon = insert-only on `registrations` (no reads ever); authenticated admin can read registrations and manage prizes. Anon can read `prizes` and call `claim_prize`.
- Project ref `esydiawzpmtgnugpaodn`; SQL via pooler `aws-0-ap-northeast-1.pooler.supabase.com:6543` (direct host is IPv6-only).

## Admin
- `/admin.html`, single Supabase Auth user (`fardeen@loveboo.com`); no signup form.
- Prize tab: toggle "On wheel" (hides without deleting history), edit quantity and `given_count` manually, replace image, delete.

## Known quirks / things to remember
- Odds are equal per slice and chosen in the browser — a tech-savvy guest could in theory tamper with the pick; stock is still enforced server-side by `claim_prize`.
- To make a prize rarer without weights, there is currently no option; weights would need a new column + weighted pick (or a server-side RPC that does the pick).
- External decorative images (floral scatter) are loaded from Shopify CDN.

## Change log
- 2026-10-18 — Created this file.
- 2026-10-18 — Switched pick from uniform to stock-weighted (TRY_AGAIN_SHARE 0.25); Mystery Gift = prize with quantity 10.
- 2026-10-18 — Responsive pass on index.html: wheel size = min(width, 26rem, viewport height minus chrome) via `.lb-wheel-stage`; compact header/gaps and hidden subtitle under 820px height; prize reveal image sized by viewport height; form is 2-column at md+ (names, email/phone side by side). Bumped sw cache to v10.
- 2026-10-18 — Prize reveal image enlarged: up to 30rem, limited by viewport height (`.lb-prize-image`).
- 2026-10-18 — Mobile/tablet registrations missing: likely Klaviyo rejecting the whole signup for a malformed phone (autofilled number + dial code doubled), which blocked the Supabase write (admin is Klaviyo-gated) and left the guest stuck in that phone's localStorage queue. Fixes: phone normalizer strips a duplicated dial code; `sendKlaviyoOnce` retries once without phone on a 4xx. Queued items live only in the guest's own browser until flushed.
- 2026-10-18 — Reliability audit + rebuild of delivery: outbox pattern, Supabase/Klaviyo decoupled, timeouts, instant reveal, inline validation, self-hosted vendor libs, admin pagination, removed viewport zoom lock. Tested with mocked failures (bad phone, Klaviyo 500, Supabase down): nothing lost, all recovered.

## Reliability layer v2 (needs `supabase/reliability.sql` run once in the SQL Editor)
- **Server-side spin**: `spin_wheel()` RPC does the stock-weighted pick (same weights/25% Try Again as before) AND the atomic stock claim in one transaction. `doSpin()` calls it first; the registration is saved to the outbox *before* the animation. If the RPC isn't installed or errors/times out, it falls back to the in-browser `pickWeightedIndex()` + `claim_prize`.
- **Idempotent registrations**: each registration carries a `client_id` (uuid); inserted via upsert with `ignoreDuplicates` on `client_id`, so retries can't duplicate. If the column isn't there yet, it falls back to a plain insert. (Separate from the "no dedup" decision: distinct guests/submissions are still never blocked.)
- Index on `registrations(created_at desc)`.
- `admin.html` now also uses self-hosted `vendor/` libs (incl. `alpine.min.js`).

## Still open
- Klaviyo import is manual (CSV). A live server-side sync would need a Klaviyo **private** API key — not set up.
- Tailwind still runs as the browser runtime (self-hosted); precompiling would need a build step, which the project deliberately avoids.
- Dashboard tasks: enable Supabase backups/PITR; real-device test (iPhone, Android, tablet, laptop).
- 2026-10-18 — Added `supabase/reliability.sql` (client_id, index, spin_wheel RPC), server-side spin with fallback, idempotent upsert, admin vendored, SW cache v12.
- 2026-10-18 — Removed Klaviyo from the guest page (Supabase-only; the earlier Klaviyo-decoupling entries above are historical); added admin "Export for Klaviyo" CSV (all / new since last / today, matches Klaviyo's List Import Template); SW v13 (cache-first vendor, offline fallback); manifest shortcuts/categories/description.
