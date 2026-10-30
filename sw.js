/* Complichess service worker — offline play + instant updates.
   Network first for the game page and version.json, so a new release reaches players on the next
   launch without reinstalling. The cached copy is only used when there is no connection.
   The cache name follows the version in the registration URL (sw.js?v=2.1.0). */
const VERSION = new URL(self.location).searchParams.get('v') || 'dev';
const CACHE = 'complichess-' + VERSION;
const CORE = ['./', 'index.html', 'legal.html', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'apple-touch-icon.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(CORE.map((u) => new Request(u, { cache: 'reload' })))).catch(() => {}));
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('complichess-') && k !== CACHE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('message', (e) => { if (e.data === 'skipWaiting') self.skipWaiting(); });

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // online play, accounts etc. go straight to the network
  if (url.pathname.endsWith('/version.json')) return; // always live
  if (url.pathname.endsWith('/admin.html')) return; // the admin page is always live and never cached
  const isPage = req.mode === 'navigate' || url.pathname.endsWith('/') || url.pathname.endsWith('.html');
  if (isPage) {
    // the game itself is cached as index.html; other pages (legal.html) under their own name
    const isGame = url.pathname.endsWith('/') || url.pathname.endsWith('/index.html');
    const key = isGame ? 'index.html' : url.pathname.split('/').pop();
    e.respondWith((async () => {
      try {
        const fresh = await fetch(req, { cache: 'no-cache' });
        if (fresh && fresh.ok) { const c = await caches.open(CACHE); c.put(key, fresh.clone()); }
        return fresh;
      } catch (err) {
        return (await caches.match(key)) || (isGame ? await caches.match('./') : null) || Response.error();
      }
    })());
    return;
  }
  e.respondWith((async () => {
    const hit = await caches.match(req);
    if (hit) return hit;
    try {
      const res = await fetch(req);
      if (res && res.ok) { const c = await caches.open(CACHE); c.put(req, res.clone()); }
      return res;
    } catch (err) { return Response.error(); }
  })());
});
