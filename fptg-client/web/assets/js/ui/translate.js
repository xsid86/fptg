import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { store, onActiveChat } from '../core/store.js';
import { call } from '../core/net.js';
import { invalidateHistory } from './history.js';

// Translating a chat's messages — on Telegram's side (message.translate ->
// translateMessageText). The button under "i" turns it on for the open
// chat; the choice is remembered per chat.
//
// Only what got on screen is translated: the message node is given to the
// observer (watchTranslation), and the request goes when it is visible —
// no more than TRANSLATE_PARALLEL at once. A ready translation — in the cache
// by chat+message+language; the history is redrawn (invalidateHistory), the
// message draws the translation instead of the text (translationFor in message.js).

const ON_KEY = 'tg.translate.chats';
const TRANSLATE_PARALLEL = 3;
// One redraw of the history after a batch of translations, not one for each.
const REDRAW_DELAY_MS = 200;

let toggle = null;
let hooks = {};
let enabled = new Set();
const cache = new Map();        // key -> { text, entities } | 'pending' | 'failed'
const watched = new WeakMap();  // node -> message
let observer = null;
const queue = [];
let running = 0;
let redrawTimer = 0;
let reported = false;

function loadEnabled() {
  try {
    enabled = new Set(JSON.parse(localStorage.getItem(ON_KEY) || '[]').map(String));
  } catch {
    enabled = new Set();
  }
}

function saveEnabled() {
  try {
    localStorage.setItem(ON_KEY, JSON.stringify([...enabled]));
  } catch { /* without storage — until a reload */ }
}

/** The translation language — the system language (a code Telegram understands). */
export function targetLang() {
  const nav = (navigator.language || 'en').toLowerCase();
  if (nav.startsWith('zh')) return nav.includes('tw') || nav.includes('hant') ? 'zh-TW' : 'zh-CN';
  if (nav === 'pt-br') return 'pt-BR';
  return nav.split('-')[0];
}

const isOn = () => store.activeChatId !== null && enabled.has(String(store.activeChatId));
// The messages lie in the model's chat (in a thread — the discussion group).
const keyOf = (msg) => `${store.messages?.chatId}:${msg.id}:${targetLang()}`;

/** A message's translation, if the chat's translation is on and it is ready; otherwise null. */
export function translationFor(msg) {
  if (!isOn() || !msg?.text) return null;
  const t = cache.get(keyOf(msg));
  return t && typeof t === 'object' ? t : null;
}

function scheduleRedraw() {
  clearTimeout(redrawTimer);
  redrawTimer = setTimeout(() => invalidateHistory(), REDRAW_DELAY_MS);
}

function pump() {
  while (running < TRANSLATE_PARALLEL && queue.length) {
    const msg = queue.shift();
    const key = keyOf(msg);
    if (cache.has(key) && cache.get(key) !== 'pending') continue;
    running += 1;
    call('message.translate', { id: String(msg.id), lang: targetLang() })
      .then((r) => {
        cache.set(key, { text: r?.text ?? '', entities: r?.entities ?? [] });
        scheduleRedraw();
      })
      .catch((error) => {
        cache.set(key, 'failed');
        // One complaint per turning on, not one per message.
        if (!reported) {
          reported = true;
          hooks.report?.(error);
        }
      })
      .finally(() => {
        running -= 1;
        pump();
      });
  }
}

/** A message node: translate it when it gets on screen. */
export function watchTranslation(node, msg) {
  if (!isOn() || !msg?.text || !node) return;
  if (cache.has(keyOf(msg))) return;
  if (!observer) {
    observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const m = watched.get(entry.target);
        observer.unobserve(entry.target);
        if (!m || !isOn()) continue;
        const key = keyOf(m);
        if (cache.has(key)) continue;
        cache.set(key, 'pending');
        queue.push(m);
      }
      pump();
    });
  }
  watched.set(node, msg);
  observer.observe(node);
}

function render() {
  if (!toggle) return;
  toggle.hidden = store.activeChatId === null;
  const on = isOn();
  toggle.classList.toggle('is-on', on);
  toggle.setAttribute('aria-pressed', String(on));
  toggle.title = on ? 'Show original' : `Translate to ${targetLang()}`;
}

function flip() {
  const id = String(store.activeChatId);
  if (enabled.has(id)) enabled.delete(id);
  else enabled.add(id);
  saveEnabled();
  reported = false;
  render();
  invalidateHistory();
}

/** hooks: { report(err) } */
export function mountTranslate(box, options) {
  hooks = options ?? {};
  loadEnabled();
  toggle = el('button', {
    class: 'translate-toggle', type: 'button', hidden: true, 'aria-pressed': 'false',
    onclick: flip,
  }, el('span', { class: 'translate-toggle__glyph', 'aria-hidden': 'true' }, '文A'),
  el('span', { class: 'u-sr-only' }, 'Translate'));
  box.append(toggle);
  onActiveChat(render);
  on('store:messages', () => {
    if (!isOn()) return;
    pump();
  });
  render();
}
