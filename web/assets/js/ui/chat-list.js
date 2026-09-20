import { el, clear } from '../core/dom.js';
import { on } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { icon, kindIcon } from '../util/icons.js';
import { listTime, countLabel, initial } from '../util/format.js';

// Renders the chat list and nothing else. It reports a click through
// the store and never touches the header or the history directly.

let root = null;

function chatItem(chat) {
  const flags = [];
  if (chat.pinned) flags.push(icon('pin', 'icon--sm'));
  if (chat.muted) flags.push(icon('bell-off', 'icon--sm'));
  if (chat.archived) flags.push(icon('archive', 'icon--sm'));

  const head = el('div', { class: 'chat-item__head' },
    icon(kindIcon(chat.kind), 'chat-item__kind'),
    el('span', { class: 'chat-item__title', textContent: chat.title || '(no title)' }),
    el('span', { class: 'chat-item__flags' }, flags),
    el('span', { class: 'chat-item__time u-tabular', textContent: listTime(chat.date) }),
  );

  const preview = el('span', { class: 'chat-item__preview' });
  if (chat.outgoing) preview.append(el('span', { class: 'chat-item__me', textContent: 'You: ' }));
  preview.append(document.createTextNode(chat.preview || ''));

  const meta = el('div', { class: 'chat-item__meta' });
  if (chat.folder) {
    meta.append(el('span', { class: 'chip chat-item__folder' },
      el('span', { textContent: chat.folder })));
  }
  if (chat.unread > 0) {
    meta.append(el('span', {
      class: `badge${chat.muted ? ' badge--muted' : ''}`,
      textContent: countLabel(chat.unread),
    }));
  }

  const body = el('div', { class: 'chat-item__body' },
    el('span', { class: 'avatar chat-item__avatar', textContent: initial(chat.title) }),
    el('span', { class: 'chat-item__text' }, preview),
    meta,
  );

  const item = el('button', {
    class: [
      'chat-item',
      // The accent is a class out of the fixed palette (chat.color is a
      // key like "a12" or "f3", resolved server-side), never an inline
      // colour. scss/base/_accent.scss turns it into --accent-color.
      `accent-${chat.color}`,
      chat.outgoing ? 'is-outgoing' : '',
      chat.muted ? 'chat-item--muted' : '',
      chat.kind === 'secret' ? 'chat-item--secret' : '',
      chat.id === store.activeChatId ? 'is-active' : '',
    ].filter(Boolean).join(' '),
    type: 'button',
    dataset: { chatId: String(chat.id) },
    onclick: () => setActiveChat(chat.id),
  }, head, body);

  return item;
}

function render() {
  if (!root) return;
  clear(root);
  const chats = store.chats;
  if (!chats.length) {
    root.append(el('div', { class: 'chat-list__empty', textContent: 'No chats here yet.' }));
    return;
  }
  const fragment = document.createDocumentFragment();
  for (const chat of chats) fragment.append(chatItem(chat));
  root.append(fragment);
}

export function mountChatList(node) {
  root = node;
  on('store:chats', render);
  // Re-render on selection so the previously active card drops its
  // highlight; the list is small enough that a full rebuild is cheaper
  // than tracking which two nodes changed.
  on('store:active', render);
  render();
}

export function showListLoading(node) {
  clear(node).append(el('div', { class: 'chat-list__loading' },
    el('span', { class: 'spinner' }), 'loading chats...'));
}

export function showListError(node, message) {
  clear(node).append(el('div', { class: 'chat-list__empty' },
    el('div', { class: 'u-dim', textContent: message })));
}
