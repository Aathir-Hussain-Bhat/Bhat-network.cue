// Network-only for app/data requests; branding assets are cached for offline startup.
const BRAND_CACHE = 'bhat-network-brand-v2';
const BRAND_ASSETS = [
  './manifest.webmanifest',
  './assets/branding/bhat-network-32.png',
  './assets/branding/bhat-network-180.png',
  './assets/branding/bhat-network-192.png',
  './assets/branding/bhat-network-512.png'
];

self.addEventListener('install', event => event.waitUntil(
  caches.open(BRAND_CACHE).then(cache => cache.addAll(BRAND_ASSETS)).then(() => self.skipWaiting())
));
self.addEventListener('activate', event => event.waitUntil(
  caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith('bhat-network-brand-') && key !== BRAND_CACHE)
      .map(key => caches.delete(key))
  )).then(() => self.clients.claim())
));
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.method === 'GET' && url.origin === self.location.origin &&
      (url.pathname.endsWith('/manifest.webmanifest') || url.pathname.includes('/assets/branding/'))) {
    event.respondWith(caches.match(event.request).then(cached => cached || fetch(event.request)));
    return;
  }
  if (event.request.mode === 'navigate') event.respondWith(fetch(event.request));
});
