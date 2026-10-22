import { emit } from '../core/bus.js';

// Settings of this window's look — what Telegram Desktop keeps in its local
// settings, not in the account: how to send (Enter or Ctrl+Enter), whether
// to loop stickers, whether GIFs start by themselves, interface animations,
// scale. They live in this page's localStorage, like the accent and the
// traffic display: another device has its own choice.
//
// They are read on the spot (prefs.get), a change — the pref:<key> event;
// what is expressed by a root class (scale, animations) is set here.

const KEY = 'viewPrefs';

const DEFAULTS = {
  sendByCtrlEnter: false,   // Ctrl+Enter sends, Enter — a new line
  loopStickers: false,      // animated stickers — in a loop, not once
  autoplayGifs: true,       // GIFs play by themselves while on screen
  animatedStickers: true,   // stickers come alive at all (Battery and animation)
  interfaceAnimations: true,
  folderTags: true,         // folder chips in the list rows (Folders)
  scale: 100,               // the interface scale, %
  callRelay: 'auto',        // calls through the server's relay: auto | on | off (calls/relay.js)
  messageSound: true,       // a chime for a new message (util/sounds.js)
  callRingtone: true,       // the ringtone of an incoming call (util/sounds.js)
};

// The scale ladder — the root classes .ui-scale-N (blocks/_settings.scss).
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
    // It will not be remembered until the next run, but it applies now.
  }
  applyRoot();
  emit(`pref:${key}`, value);
}

/** Root classes: the scale and interface animations turned off. */
export function applyRoot() {
  const root = document.documentElement;
  for (const s of SCALES) root.classList.toggle(`ui-scale-${s}`, s !== 100 && read().scale === s);
  root.classList.toggle('no-motion', !read().interfaceAnimations);
  root.classList.toggle('no-folder-tags', !read().folderTags);
}
