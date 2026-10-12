import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { store, onActiveChat } from '../core/store.js';
import { call } from '../core/net.js';
import { invalidateHistory } from './history.js';

// Перевод сообщений чата — на стороне Telegram (message.translate ->
// translateMessageText). Кнопка под «i» включает его для открытого чата;
// выбор запоминается по чату.
//
// Переводится только то, что попало на экран: узел сообщения отдаётся
// наблюдателю (watchTranslation), и запрос уходит, когда он виден — не
// больше TRANSLATE_PARALLEL разом. Готовый перевод — в кеше по
// чату+сообщению+языку; история перерисовывается (invalidateHistory),
// сообщение рисует перевод вместо текста (translationFor в message.js).

const ON_KEY = 'tg.translate.chats';
const TRANSLATE_PARALLEL = 3;
// Перерисовка истории после пачки переводов — одна, а не на каждый.
const REDRAW_DELAY_MS = 200;

let toggle = null;
let hooks = {};
let enabled = new Set();
const cache = new Map();        // ключ -> { text, entities } | 'pending' | 'failed'
const watched = new WeakMap();  // узел -> сообщение
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
  } catch { /* без хранилища — до перезагрузки */ }
}

/** Язык перевода — язык системы (код, который понимает Telegram). */
export function targetLang() {
  const nav = (navigator.language || 'en').toLowerCase();
  if (nav.startsWith('zh')) return nav.includes('tw') || nav.includes('hant') ? 'zh-TW' : 'zh-CN';
  if (nav === 'pt-br') return 'pt-BR';
  return nav.split('-')[0];
}

const isOn = () => store.activeChatId !== null && enabled.has(String(store.activeChatId));
// Сообщения лежат в чате модели (в ветке — группа обсуждения).
const keyOf = (msg) => `${store.messages?.chatId}:${msg.id}:${targetLang()}`;

/** Перевод сообщения, если перевод чата включён и он уже готов; иначе null. */
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
        // Одна жалоба на включение, а не на каждое сообщение.
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

/** Узел сообщения: перевести, когда окажется на экране. */
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
