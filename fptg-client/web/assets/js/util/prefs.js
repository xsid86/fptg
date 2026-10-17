import { emit } from '../core/bus.js';

// Настройки вида этого окна — то, что у Telegram Desktop лежит в его
// локальных настройках, а не в аккаунте: как отправлять (Enter или
// Ctrl+Enter), зацикливать ли стикеры, запускать ли GIF сами, анимации
// интерфейса, масштаб. Живут в localStorage этой страницы, как акцент и
// показ трафика: у другого устройства — свой выбор.
//
// Читают их на месте (prefs.get), поменялось — событие pref:<ключ>;
// то, что выражается классом корня (масштаб, анимации), ставится здесь.

const KEY = 'viewPrefs';

const DEFAULTS = {
  sendByCtrlEnter: false,   // Ctrl+Enter отправляет, Enter — новая строка
  loopStickers: false,      // анимированные стикеры — по кругу, а не один раз
  autoplayGifs: true,       // GIF играют сами, пока на экране
  animatedStickers: true,   // стикеры вообще оживают (Battery and animation)
  interfaceAnimations: true,
  folderTags: true,         // чипы папок в строках списка (Folders)
  scale: 100,               // масштаб интерфейса, %
};

// Лестница масштаба — классы корня .ui-scale-N (blocks/_settings.scss).
export const SCALES = [100, 110, 125, 150, 175, 200];

let prefs = null;

function read() {
  if (prefs) return prefs;
  let saved = {};
  try {
    saved = JSON.parse(localStorage.getItem(KEY) ?? '{}') ?? {};
  } catch {
    saved = {};
  }
  prefs = { ...DEFAULTS };
  for (const k of Object.keys(DEFAULTS)) {
    if (typeof saved[k] === typeof DEFAULTS[k]) prefs[k] = saved[k];
  }
  if (!SCALES.includes(prefs.scale)) prefs.scale = 100;
  return prefs;
}

export function getPref(key) {
  return read()[key];
}

export function setPref(key, value) {
  read()[key] = value;
  try {
    localStorage.setItem(KEY, JSON.stringify(prefs));
  } catch {
    // Не запомнится до следующего запуска, но сейчас подействует.
  }
  applyRoot();
  emit(`pref:${key}`, value);
}

/** Классы корня: масштаб и выключенные анимации интерфейса. */
export function applyRoot() {
  const root = document.documentElement;
  for (const s of SCALES) root.classList.toggle(`ui-scale-${s}`, s !== 100 && read().scale === s);
  root.classList.toggle('no-motion', !read().interfaceAnimations);
  root.classList.toggle('no-folder-tags', !read().folderTags);
}
