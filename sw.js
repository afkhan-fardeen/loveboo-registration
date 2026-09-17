// App-shell cache only. Never intercepts POSTs or cross-origin API calls
// (Supabase, Klaviyo) — those always go straight to the network so the
// existing retry/backup-queue logic in the pages keeps working exactly as
// before. This only makes the page itself load instantly (and even offline)
// on a kiosk with flaky venue wifi.
const CACHE_VERSION = "lb-shell-v3";
const SHELL_ASSETS = [
  "/",
  "/index.html",
  "/admin.html",
  "/supabase-config.js",
  "/manifest.json",
  "/favicon.png",
  "/icons/icon-192.png",
  "/icons/icon-512.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(SHELL_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((key) => key !== CACHE_VERSION).map((key) => caches.delete(key))
      )
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const req = event.request;

  // Only ever handle same-origin GET requests for the app shell.
  // Everything else (Supabase, Klaviyo, any POST) passes straight through.
  if (req.method !== "GET" || new URL(req.url).origin !== self.location.origin) {
    return;
  }

  // Network-first so updates always show up immediately; falls back to the
  // cached shell only when the network is actually unreachable.
  event.respondWith(
    fetch(req)
      .then((res) => {
        if (res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(req, copy));
        }
        return res;
      })
      .catch(() => caches.match(req))
  );
});
