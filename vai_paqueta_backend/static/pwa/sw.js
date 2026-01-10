const CACHE_VERSION = 'v1';
const CACHE_NAME = `vp-webapp-${CACHE_VERSION}`;

const APP_SHELL = [
  '/app/',
  '/static/landing/assets/css/bootstrap.min.css',
  '/static/landing/assets/css/LineIcons.2.0.css',
  '/static/landing/assets/css/main.css',
  '/static/leaflet/leaflet.css',
  '/static/landing/assets/js/bootstrap.min.js',
  '/static/leaflet/leaflet.js',
  '/static/landing/assets/images/logo/logo-collor.png',
  '/static/landing/data/addresses.json',
  '/static/pwa/icon-180.png',
  '/static/pwa/icon-192.png',
  '/static/pwa/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

async function networkFirst(request) {
  try {
    const response = await fetch(request);
    const cache = await caches.open(CACHE_NAME);
    cache.put(request, response.clone());
    return response;
  } catch (err) {
    const cached = await caches.match(request);
    if (cached) return cached;
    return caches.match('/app/');
  }
}

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  const cache = await caches.open(CACHE_NAME);
  cache.put(request, response.clone());
  return response;
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);

  if (url.pathname.startsWith('/api/')) return;

  if (request.mode === 'navigate' && url.pathname.startsWith('/app')) {
    event.respondWith(networkFirst(request));
    return;
  }

  if (url.pathname.startsWith('/static/')) {
    event.respondWith(cacheFirst(request));
  }
});
