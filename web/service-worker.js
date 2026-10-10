// Freestone County ARES Tactical Mobile Service Worker (v11)
// Enables 100% offline field operation with Network-First updates for latest tactical changes.
// Pure Free OpenStreetMap & ESRI Satellite (ZERO API KEYS REQUIRED).

const CACHE_NAME = 'fc-ares-tactical-v11';
const TILE_CACHE_NAME = 'fc-ares-maptiles-v1';

const ASSETS_TO_CACHE = [
  './',
  './index.html',
  './ares_tactical_preview.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './apple-touch-icon.png',
  './tactical_patch_optimized.jpg',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'
];

// Offline Fallback SVG Map Tile
const OFFLINE_SVG_TILE = `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect width="256" height="256" fill="#070a0f"/>
  <path d="M 0,0 L 256,0 L 256,256 L 0,256 Z" fill="none" stroke="#064e3b" stroke-width="1" opacity="0.3"/>
  <line x1="0" y1="128" x2="256" y2="128" stroke="#064e3b" stroke-width="1" stroke-dasharray="4,4" opacity="0.4"/>
  <line x1="128" y1="0" x2="128" y2="256" stroke="#064e3b" stroke-width="1" stroke-dasharray="4,4" opacity="0.4"/>
  <text x="128" y="124" fill="#10b981" font-size="10" font-family="monospace" font-weight="bold" text-anchor="middle" opacity="0.7">FREESTONE CO. ARES</text>
  <text x="128" y="140" fill="#64748b" font-size="8" font-family="monospace" text-anchor="middle" opacity="0.8">OFFLINE TILE GRID</text>
</svg>`;

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      console.log('[ARES Tactical SW v11] Pre-caching core emergency tactical assets & Leaflet engine...');
      return cache.addAll(ASSETS_TO_CACHE).catch((err) => {
        console.warn('[ARES Tactical SW v11] Notice: Non-critical asset cache deferred:', err);
      });
    }).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keyList) => {
      return Promise.all(
        keyList.map((key) => {
          if (key !== CACHE_NAME && key !== TILE_CACHE_NAME) {
            console.log('[ARES Tactical SW v11] Removing superseded cache:', key);
            return caches.delete(key);
          }
        })
      );
    }).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // 1. Intercept OpenStreetMap and ESRI World Imagery tile requests (Zero API Keys)
  const isMapTile = url.hostname.includes('tile.openstreetmap.org') ||
                    url.hostname.includes('server.arcgisonline.com');

  if (isMapTile) {
    event.respondWith(
      caches.open(TILE_CACHE_NAME).then((tileCache) => {
        return tileCache.match(event.request).then((cachedTile) => {
          if (cachedTile) {
            return cachedTile;
          }
          return fetch(event.request).then((networkResponse) => {
            if (networkResponse && networkResponse.status === 200) {
              tileCache.put(event.request, networkResponse.clone());
            }
            return networkResponse;
          }).catch(() => {
            return new Response(OFFLINE_SVG_TILE, {
              headers: { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'public, max-age=86400' }
            });
          });
        });
      })
    );
    return;
  }

  // 2. HTML & Navigation Documents: NETWORK-FIRST (Guarantees freshest tactical changes immediately)
  const isHtml = event.request.mode === 'navigate' ||
                 event.request.destination === 'document' ||
                 url.pathname.endsWith('.html') ||
                 url.pathname === '/' ||
                 url.pathname.endsWith('/');

  if (isHtml) {
    event.respondWith(
      fetch(event.request).then((networkResponse) => {
        if (networkResponse && networkResponse.status === 200) {
          const responseToCache = networkResponse.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, responseToCache));
        }
        return networkResponse;
      }).catch(() => {
        return caches.match(event.request).then((cached) => cached || caches.match('./index.html') || caches.match('./ares_tactical_preview.html'));
      })
    );
    return;
  }

  // 3. Static Assets (Images, Stylesheets, Icons): Cache-First Strategy
  event.respondWith(
    caches.match(event.request).then((cachedResponse) => {
      if (cachedResponse) {
        return cachedResponse;
      }
      return fetch(event.request).then((networkResponse) => {
        if (networkResponse && networkResponse.status === 200 && networkResponse.type === 'basic') {
          const responseToCache = networkResponse.clone();
          caches.open(CACHE_NAME).then((cache) => {
            cache.put(event.request, responseToCache);
          });
        }
        return networkResponse;
      });
    })
  );
});
