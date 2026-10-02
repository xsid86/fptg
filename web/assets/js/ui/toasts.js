import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';

// Pop-ups for messages that arrive while you are looking at something
// else - the card with the chat's picture on it, the way a real client
// draws them.
//
// This is only HALF of the feature, and deliberately so. A page cannot
// put anything on screen when its window is behind another one or in
// the tray, and WebView2 will not help: it denies the Notification
// permission by default and, even granted, shows nothing itself - the
// host has to. So the other half lives in Pascal, where the tray icon
// raises a real Windows notification, and webapi.pas picks between the
// two by asking whether this window is the one on screen.
//
// Both halves are fed by the same `arrival` event, so the page still
// has to decide for itself: it is not always THIS window (the same
// page opens in an ordinary browser too), and it must not talk to
// nobody.

const LIMIT = 4;            // more than this is a wall, not a notice
const LIFE_MS = 6000;

let stack = null;
let clearAll = null;
// Карточка -> её таймер: сколько ей ещё жить и с какого момента идёт
// отсчёт. Отсчёт идёт ТОЛЬКО пока окно в фокусе: карточка, пришедшая,
// пока человек был в другой программе, иначе исчезла бы раньше, чем на
// неё посмотрели. Наведённая (pinned) не закрывается сама вовсе.
const life = new Map();

export function mountToasts(node) {
  stack = node;
  // Над карточками, той же ширины; видна, только пока есть что скрывать.
  clearAll = el('button', {
    class: 'toast-stack__clear',
    type: 'button',
    hidden: true,
    onclick: () => {
      for (const card of [...life.keys()]) drop(card);
    },
  }, 'Hide all');
  stack.prepend(clearAll);

  on('srv:arrival', arrived);
  window.addEventListener('blur', pauseAll);
  window.addEventListener('focus', resumeAll);
}

function start(card) {
  const t = life.get(card);
  if (!t || t.pinned || t.timer) return;
  t.since = Date.now();
  t.timer = setTimeout(() => drop(card), t.left);
}

function pause(card) {
  const t = life.get(card);
  if (!t || !t.timer) return;
  clearTimeout(t.timer);
  t.timer = 0;
  t.left = Math.max(0, t.left - (Date.now() - t.since));
}

function pauseAll() {
  for (const card of life.keys()) pause(card);
}

function resumeAll() {
  for (const card of life.keys()) start(card);
}

const cards = () => [...life.keys()];

function syncClearAll() {
  if (clearAll) clearAll.hidden = life.size === 0;
}

function arrived(data) {
  if (!stack || !data) return;
  // Nobody is looking at this page: the window is minimised, or it is
  // another tab. Pascal has already raised a system notification for
  // the window it belongs to - a card queued up here would only be
  // read minutes later, out of its moment.
  if (document.visibilityState !== 'visible') return;
  // The chat is already open and on screen. Telling someone about a
  // message they are reading is noise.
  if (data.chatId === store.activeChatId) return;

  show(data);
}

function show(data) {
  const card = el('div', { class: `toast accent-${data.color}` });

  const avatar = el('span', { class: 'avatar avatar--sm toast__avatar' });
  // The same picture the list row and the header draw - see
  // util/avatar.js. `avatar` may be empty here, which is exactly the
  // case that builder exists for.
  fillAvatar(avatar, { title: data.title, avatar: data.avatar });

  card.append(
    avatar,
    el('div', { class: 'toast__body' },
      el('div', { class: 'toast__title', textContent: data.title || '(no title)' }),
      el('div', { class: 'toast__text', textContent: data.text || '' })),
    el('button', {
      class: 'toast__close',
      type: 'button',
      title: 'Dismiss',
      onclick: (event) => {
        // Or the click would also open the chat underneath.
        event.stopPropagation();
        drop(card);
      },
    }, icon('close', 'icon--sm')),
  );

  card.addEventListener('click', () => {
    setActiveChat(data.chatId);
    drop(card);
  });

  stack.append(card);
  life.set(card, { left: LIFE_MS, since: 0, timer: 0, pinned: false });
  // The oldest go first, so the newest is always the one at hand.
  while (life.size > LIMIT) drop(cards()[0]);
  syncClearAll();

  if (document.hasFocus()) start(card);
  card.addEventListener('pointerenter', () => {
    pause(card);
    life.get(card).pinned = true;
  });
  // Left alone after a hover rather than restarted: the reader has
  // shown interest, and a card that vanishes from under the pointer is
  // the thing that makes these infuriating.
}

function drop(card) {
  if (!card) return;
  const t = life.get(card);
  if (t?.timer) clearTimeout(t.timer);
  life.delete(card);
  card.remove();
  syncClearAll();
}
