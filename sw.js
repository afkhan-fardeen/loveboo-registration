// App-shell cache only. Never intercepts POSTs or cross-origin API calls
// (Supabase) — those always go straight to the network so the
// existing retry/backup-queue logic in the pages keeps working exactly as
// before. This only makes the page itself load instantly (and even offline)
// on a kiosk with flaky venue wifi.
const CACHE_VERSION = "lb-shell-v20";
const SHELL_ASSETS = [
  "/",
  "/index.html",
  "/admin.html",
  "/wheel.html",
  "/supabase-config.js",
  "/vendor/daisyui.css",
  "/vendor/tailwind-browser.js",
  "/vendor/supabase.js",
  "/vendor/alpine.min.js",
  "/vendor/anime.min.js",
  "/vendor/confetti.browser.min.js",
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
  const url = new URL(req.url);

  // Only ever handle same-origin GET requests for the app shell.
  // Everything else (Supabase, any POST) passes straight through.
  if (req.method !== "GET" || url.origin !== self.location.origin) {
    return;
  }

  // Versioned third-party libraries never change: serve from cache first
  // (instant, works offline), fetch only when missing.
  if (url.pathname.startsWith("/vendor/")) {
    event.respondWith(
      caches.match(req).then((hit) => hit || fetch(req).then((res) => {
        if (res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(req, copy));
        }
        return res;
      }))
    );
    return;
  }

  // Everything else: network-first so updates show up immediately; falls
  // back to the cached shell when the network is unreachable. A page
  // navigation that can't be matched falls back to the cached home page.
  event.respondWith(
    fetch(req)
      .then((res) => {
        if (res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(req, copy));
        }
        return res;
      })
      .catch(() => caches.match(req).then((hit) => hit || (req.mode === "navigate" ? caches.match("/") : undefined)))
  );
});
