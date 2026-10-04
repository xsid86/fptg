import { emit } from '../core/bus.js';
import { el } from '../core/dom.js';
import { openLink } from '../ui/links.js';

// Картинки карт для геопозиций в сообщениях.
//
// Карту рисует сам Telegram (getMapThumbnailFile на сервере, map.thumb в
// мосте), а сообщение строится синхронно — поэтому здесь кэш по
// координатам: первый вызов просит картинку и возвращает null, а когда она
// приехала, событие ui:map-ready перерисовывает историю (main.js).

const cache = new Map();   // "lat,lon" -> адрес ('' — не вышло)
const asked = new Set();
let fetcher = null;

/** Чем просить картинку: (lat, lon) => Promise<url>. Ставит main.js. */
export function setMapFetcher(fn) {
  fetcher = fn;
}

/** Адрес картинки карты или null, пока её нет. */
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

// --------------------------------------------------------- сервисы
// Где открыть точку. Коды — те же, что MAPS_PROVIDERS в constants.pas;
// адреса — публичные ссылки «показать точку» каждого сервиса.
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

let provider = '';      // сервис по умолчанию; '' — спрашивать
let saver = null;       // (id) => сохранить выбор (settings.set, main.js)

/** Сервис по умолчанию — из settings.get / события settings. */
export function setMapProvider(id) {
  provider = MAP_PROVIDERS.some((p) => p.id === id) ? id : '';
}

/** Как сохранить выбор «запомнить». Ставит main.js. */
export function setMapSaver(fn) {
  saver = fn;
}

/**
 * Открыть точку во внешнем сервисе карт: в выбранном по умолчанию или —
 * если он не задан — после окна выбора с галочкой «Remember my choice».
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
