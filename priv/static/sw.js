// Huddy's service worker. Pages always come from the network (they are live
// and signed in); when the server can't be reached, the cached offline page
// stands in. The offline page's own assets are kept for that, and refreshed
// whenever the network serves them. Everything else (the event stream, posts,
// documents, other origins) is left to the browser.
const CACHE = "huddy-v1";
const OFFLINE = "/offline";
const KEEP = [
  OFFLINE,
  "/static/huddy.css",
  "/static/excalifont.woff2",
  "/static/nunito.woff2",
  "/static/favicon.svg",
];

self.addEventListener("install", (ev) => {
  ev.waitUntil(
    caches.open(CACHE)
      .then((cache) => cache.addAll(KEEP))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (ev) => {
  ev.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (ev) => {
  const req = ev.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;
  if (req.mode === "navigate") {
    ev.respondWith(
      fetch(req).catch(() =>
        caches.match(OFFLINE).then((res) => res || Response.error()),
      ),
    );
  } else if (KEEP.includes(url.pathname)) {
    ev.respondWith(
      fetch(req)
        .then((res) => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then((cache) => cache.put(url.pathname, copy));
          }
          return res;
        })
        .catch(() =>
          caches.match(url.pathname).then((res) => res || Response.error()),
        ),
    );
  }
});

// Notifications shown by the board (huddy.js): a click brings Huddy forward
// at the item, opening it if no window is left.
self.addEventListener("notificationclick", (ev) => {
  ev.notification.close();
  const hash = (ev.notification.data && ev.notification.data.hash) || "";
  ev.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
      const board = wins.find((w) => new URL(w.url).pathname === "/");
      if (board) {
        board.postMessage({ huddy: "show", hash });
        return board.focus();
      }
      return self.clients.openWindow("/" + hash);
    }),
  );
});
