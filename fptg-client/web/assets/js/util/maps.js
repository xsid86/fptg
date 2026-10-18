import { emit } from '../core/bus.js';
import { el } from '../core/dom.js';
import { openLink } from '../ui/links.js';

// Map pictures for locations in messages.
//
// Telegram itself draws the map (getMapThumbnailFile on the server,
// map.thumb in the bridge), while a message is built synchronously — hence
// a cache by coordinates here: the first call asks for the picture and
// returns null, and when it has arrived, the ui:map-ready event redraws the
// history (main.js).

const cache = new Map();   // "lat,lon" -> the address ('' — it failed)
const asked = new Set();
let fetcher = null;

/** How to ask for a picture: (lat, lon) => Promise<url>. Set by main.js. */
export function setMapFetcher(fn) {
  fetcher = fn;
}

/** The map picture's address or null while there is none. */
export function mapUrl(lat, lon) {
  const key = `${Number(lat).toFixed(6)},${Number(lon).toFixed(6)}`;
  if (cache.has(key)) return cache.get(key) || null;
  if (!asked.has(key) && fetcher) {
    asked.add(key);
    fetcher(lat, lon).then((url) => {
      cache.set(key, url || '');
      if (url) emit('ui:map-ready');
    }).catch(() => cache.set(key, ''));
  }
  return null;
}

// --------------------------------------------------------- services
// Where to open a point. The codes are the same as MAPS_PROVIDERS in
// constants.pas; the addresses — each service's public "show a point" links.
export const MAP_PROVIDERS = [
  { id: 'google', label: 'Google Maps',
    url: (lat, lon) => `https://www.google.com/maps/search/?api=1&query=${lat},${lon}` },
  { id: 'yandex', label: 'Yandex Maps',
    url: (lat, lon) => `https://yandex.ru/maps/?pt=${lon},${lat}&z=17&l=map` },
  { id: 'osm', label: 'OpenStreetMap',
    url: (lat, lon) => `https://www.openstreetmap.org/?mlat=${lat}&mlon=${lon}#map=17/${lat}/${lon}` },
  { id: 'bing', label: 'Bing Maps',
    url: (lat, lon) => `https://www.bing.com/maps?cp=${lat}~${lon}&lvl=17&sp=point.${lat}_${lon}_` },
  { id: 'apple', label: 'Apple Maps',
    url: (lat, lon) => `https://maps.apple.com/?ll=${lat},${lon}&q=${lat},${lon}` },
  { id: '2gis', label: '2GIS',
    url: (lat, lon) => `https://2gis.ru/?m=${lon},${lat}/17` },
  { id: 'here', label: 'HERE WeGo',
    url: (lat, lon) => `https://wego.here.com/?map=${lat},${lon},17` },
];

let provider = '';      // the default service; '' — ask
let saver = null;       // (id) => save the choice (settings.set, main.js)

/** The default service — from settings.get / the settings event. */
export function setMapProvider(id) {
  provider = MAP_PROVIDERS.some((p) => p.id === id) ? id : '';
}

/** How to save the "remember" choice. Set by main.js. */
export function setMapSaver(fn) {
  saver = fn;
}

/**
 * Open a point in an external map service: the default one or — if none is
 * set — after the choice window with the "Remember my choice" checkbox.
 */
export function openMapPoint(lat, lon) {
  const known = MAP_PROVIDERS.find((p) => p.id === provider);
  if (known) {
    openLink(known.url(lat, lon));
    return;
  }
  const dialog = el('dialog', { class: 'confirm maps-choice', 'aria-label': 'Open the map' });
  const remember = el('input', { type: 'checkbox' });
  dialog.append(
    el('p', { class: 'confirm__note confirm__note--plain' }, 'Open the location in'),
    el('div', { class: 'maps-choice__list' },
      ...MAP_PROVIDERS.map((p) => el('button', {
        class: 'maps-choice__item', type: 'button',
        onclick: () => {
          if (remember.checked) {
            provider = p.id;
            saver?.(p.id);
          }
          dialog.close();
          openLink(p.url(lat, lon));
        },
      }, p.label))),
    el('label', { class: 'confirm__check' }, remember, el('span', {}, 'Remember my choice')),
    el('div', { class: 'confirm__buttons' },
      el('button', { class: 'btn confirm__button', type: 'button', onclick: () => dialog.close() }, 'Cancel')));
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) dialog.close();
  });
  dialog.addEventListener('close', () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
}
