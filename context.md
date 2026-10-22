# Love Boo Expo — Project Context

> **Keep this file current.** After any change to logic, data model, files or infra, update the relevant section, the "Status" table and the "Last updated" line. Read this first instead of re-reading every file.

Last updated: 2026-10-19 (code at commit `8a71642`, deployed from `main`)

## 1. What this is
Registration + spin-to-win for the Love Boo booth at **Dubai Baby Expo 2026** (3-day event). A guest signs up, spins a wheel, and sees what they won; they collect the gift at the booth. Everyone who registers is saved; the list is exported later and imported into Klaviyo.

- **Stack:** plain static site (HTML/CSS/JS, no framework, no build step) on **Vercel**, auto-deployed from GitHub `main` (`afkhan-fardeen/loveboo-registration`).
- **Backend:** Supabase (Postgres, Auth, Storage, Realtime). Project ref `esydiawzpmtgnugpaodn`.
- **Klaviyo:** NOT connected live. Admin exports a CSV in Klaviyo's import format.

## 2. Status — what works now / what's pending
| Area | State |
|---|---|
| Guest flow (landing → form → wheel → reveal) | Live. Responsive; wheel and prize image scale to the viewport height so laptops don't scroll. |
| Registration storage | Live. Supabase only, via a local outbox with retries (see §4). |
| Stock-weighted odds, Mystery Gift = 10 | Live (browser-side pick + `claim_prize`). |
| Server-side spin (`spin_wheel`) + `client_id` duplicate protection | Code is live and falls back safely, but **only active after `supabase/reliability.sql` is run in the Supabase SQL Editor** (not confirmed run). |
| Admin dashboard (registrations, prizes, Klaviyo export) | Live. |
| PWA (installable, offline shell, shortcuts) | Live, service worker cache `lb-shell-v20`. |
| Klaviyo | Manual CSV import only. |
| Real-device test (iPhone, Android, tablet, laptop) | **Not done yet.** |
| Supabase backups | **To enable** in the dashboard before the event. |

## 3. Files
| File | Purpose |
|---|---|
| `index.html` | Entire guest experience; all logic in one inline `<script>`. |
| `admin.html` | Login-gated dashboard (Alpine + daisyUI): **Registrations** tab (search, plain CSV, **Export for Klaviyo**, realtime) and **Wheel Prizes** tab (add/edit/delete, image upload, quantity, "On wheel" toggle). |
| `wheel.html` | Retired; redirects to `/`. |
| `supabase-config.js` | Supabase URL + public anon key (safe client-side, protected by RLS). Never put the service-role key anywhere in the repo. |
| `vendor/` | Self-hosted libs (supabase-js, tailwind browser runtime, daisyUI css, anime.js, confetti, alpine) used by both pages. |
| `sw.js` | Service worker: network-first for the page, cache-first for `/vendor/`, offline fallback to `/`. Never touches POSTs or Supabase calls. **Bump `CACHE_VERSION` whenever shell files change.** |
| `manifest.json`, `icons/`, `favicon.png` | PWA install data; shortcuts "Register & Spin" and "Admin". |
| `vercel.json` | Clean URLs, cache headers, `noindex` on admin/wheel. |
| `supabase/klaviyo-gated-admin.sql` | Older migration (adds `klaviyo_synced`, admin UPDATE policy on `prizes`). |
| `supabase/reliability.sql` | **Run once**: `client_id` + unique index, `created_at` index, `spin_wheel()` RPC. |
| `List Import Template ….csv` | Klaviyo's sample import file; reference only, untracked. |

The `prizes` table, `claim_prize` RPC and the RLS policies were created directly in Supabase and are not in the repo's SQL.

## 4. How a guest registration works (`index.html`)
1. **Landing:** wheel preview + "Sign Up & Spin". The wheel loads active, in-stock prizes (§5).
2. **Form:** first name, last name (optional), email, phone + country code (optional), parent Yes/No, terms checkbox (which is also the marketing consent). Validation shows an inline message (`#lbFormError`); email is lowercased; the phone is normalised to `+<country><number>` and a doubled country code is stripped. Duplicate registrations are allowed on purpose (no dedup).
3. **Spin:** guest taps to spin (max 2 spins, §5). The result is shown after the animation.
4. **Save (outbox pattern):** `recordRegistration()` → `queueRegistration(row)`:
   - The row is written to the in-memory outbox and `localStorage` (`lb_outbox_v2`) **before** any network call, then sent to Supabase in the background. The guest never waits on the network.
   - 10 s timeout per attempt; 4 quick attempts, then retried every 15 s, on `online`, and when the tab becomes visible, until Supabase accepts it.
   - Each row has a `client_id` (uuid) and is sent as an upsert that ignores duplicates, so a retry after a lost response can't create a second row. Until `reliability.sql` is run, it falls back to a plain insert.
   - Old queues from earlier versions (`lb_expo_pending_queue`, `lb_expo_supabase_pending_queue`) are converted into rows on load.
5. **Reveal:** "You won: X!" with a large prize image + confetti, or "Thanks for playing".
6. A guest's row has: name, email, phone, `is_parent`, `source`, `prize` (null if none), UTM fields, `client_id`, `created_at`. `klaviyo_synced` is legacy and unused.

## 5. Prize logic
- **On the wheel:** prizes with `active = true`, in `sort_order`, minus sold-out ones (`quantity` not null and `given_count >= quantity`). `quantity = NULL` means unlimited. One **Try Again** slice is always added. If no prizes exist, a placeholder "Mystery Gift" is shown. Slices are drawn equal-sized; names are hidden on the wheel (photos only).
- **Odds are stock-weighted, not equal:** a prize's weight = remaining stock (`quantity - given_count`); unlimited prizes weigh as much as the largest limited stock; **Try Again always has a 25% share** of every spin. Example (200/100/50/10): ~42% / 21% / 10% / 2%, Try Again 25%. Odds shift automatically as stock runs down.
- **Mystery Gift:** an ordinary prize in admin with `quantity = 10` (the total for all 3 days). Its low stock makes it rare. It is **not paced per day**, so all 10 could go on day one.
- **Try Again:** on spin 1 it gives one free re-spin; on spin 2 it means no prize.
- **Where the pick happens:**
  - *Preferred:* the `spin_wheel()` Postgres RPC picks and takes the stock in one atomic step; the registration is saved before the animation.
  - *Fallback* (RPC not installed, error or 8 s timeout): `pickWeightedIndex()` in the browser, then `claim_prize(target_id)` after the animation, which increments `given_count` only while stock remains. If the claim fails, the guest gets no prize.

## 6. Admin (`/admin.html`)
- Single Supabase Auth user: `fardeen@loveboo.com`. No sign-up form.
- **Registrations:** loads all rows (paged 1000 at a time), search, live updates, stats (registrations / prizes won / parents). On phones each row is a card; on tablets and up it's a table.
- **Export for Klaviyo** (popup): scope **All**, **New since last export** (remembered per browser in `lb_last_klaviyo_export`), or **Today**; everyone is included whether or not they won. The CSV follows Klaviyo's list-import template: `email, phone number, external id, Email Marketing Consent = SUBSCRIBE + timestamp, SMS Marketing Consent = SUBSCRIBE + timestamp (only if a phone was given), firstname, lastname, Custom Property (Prize / Is Parent / Event / Source / UTM Source / UTM Medium / UTM Campaign)`. Timestamps are UTC `YYYY-MM-DD HH:mm:ss`. In Klaviyo: your list → Add profiles → Import from CSV.
- **Export CSV:** plain full dump of the filtered rows.
- **Wheel Prizes:** add (name, image, quantity), edit (including `given_count`), delete, "On wheel" toggle (hides a prize without losing its history).

## 7. Supabase / security
- Tables: `registrations`, `prizes` (`id, name, image_url, image_path, quantity, given_count, active, sort_order, created_at`). Storage bucket: `prize-images` (public).
- RLS: anon can **insert only** into `registrations` (never read); the signed-in admin can read registrations and manage prizes; anon can read `prizes` and call `claim_prize` / `spin_wheel`.
- SQL via the pooler `aws-0-ap-northeast-1.pooler.supabase.com:6543` (the direct host is IPv6-only). No database credentials are stored in the repo; run SQL in the dashboard SQL Editor.

## 8. To do / open items
1. Run `supabase/reliability.sql` in the SQL Editor (activates server-side spin and duplicate-proof retries).
2. Enable Supabase backups / PITR before the event.
3. Real-device test: register on iPhone, Android, tablet and laptop (include a phone number), confirm all four appear in admin; test a prize win and check `given_count` rises by exactly 1; do a Klaviyo export and import a small file.
4. Decide whether to pace the Mystery Gift per day (needs a daily cap).
5. Optional later: live Klaviyo sync from a server (needs a Klaviyo private API key); precompiled Tailwind (needs a build step, which was deliberately avoided).

## 9. Known limits
- Until `reliability.sql` is run, the spin pick happens in the guest's browser (tamperable in theory); stock is still enforced by `claim_prize`.
- A guest whose phone has no connection after the spin stays in that phone's storage until it reconnects and the page is open.
- Admin and guest pages still use Google Fonts and Shopify-hosted decorative images (they degrade gracefully if blocked).
- The "last export" marker is per browser, not shared across devices.

## 10. Change log
- 2026-10-18 — Context file created; stock-weighted odds (Try Again 25%); viewport-fit responsive layout and bigger prize image; phone-number cleanup; reliability audit (outbox, timeouts, inline validation, self-hosted libs, admin paging); `reliability.sql` and server-side spin with fallback.
- 2026-10-18 — Klaviyo removed from the guest page (Supabase-only); admin "Export for Klaviyo" in Klaviyo's import format; PWA update (SW v13, manifest shortcuts). Commits `dab8b06`, `8a71642`.
- 2026-10-19 — Rewrote this file as a clean current-state document.
- 2026-10-19 — Fixed signups not saving (upsert is denied for guests; now a plain insert, duplicate = delivered). Icons/favicon regenerated from `ASSETS/` (LB monogram on cream). SW v15. Guest thank-you email is sent by the ops portal (see its CONTEXT.md) via a `registration_email_to_ops` trigger on `registrations`.
- 2026-10-22 — Added `/join` (same `index.html`, rewrite in `vercel.json`): sign-up form only, then "Thank you, check your email for your discount code" (the code is only in the email); saved with source `baby_expo_2026_qr`, no prize. Use either the spin page (`/`) or `/join` at the event. Header uses `lockup.png` (Love Boo x Baby & Kids Expo). QR image: `ASSETS/loveboo-expo-qr.png|svg`. SW v17.
- 2026-10-22 — Added `/qr`: booth screen showing `qr.svg` (replace that file to change the QR; it should open `/join`). SW v18.
