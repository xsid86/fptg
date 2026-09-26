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

export function mountToasts(node) {
  stack = node;
  on('srv:arrival', arrived);
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
  // The oldest go first, so the newest is always the one at hand.
  while (stack.children.length > LIMIT) drop(stack.firstElementChild);

  const timer = setTimeout(() => drop(card), LIFE_MS);
  card.addEventListener('pointerenter', () => clearTimeout(timer));
  // Left alone after a hover rather than restarted: the reader has
  // shown interest, and a card that vanishes from under the pointer is
  // the thing that makes these infuriating.
}

function drop(card) {
  if (!card) return;
  card.remove();
}
