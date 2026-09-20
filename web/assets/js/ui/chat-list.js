import { el, clear } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { icon, kindIcon } from '../util/icons.js';
import { listTime, countLabel, initial } from '../util/format.js';

// Renders the chat list and nothing else. It reports a click through
// the store and never touches the header or the history directly.

let root = null;

/**
 * The card is a div with a button role, not a <button>.
 *
 * It has to be: the mute/pin/archive controls inside it are real
 * buttons, and a button inside a button is invalid markup that browsers
 * resolve by dropping one of them. The native row solves the same
 * problem by hit-testing rectangles inside one painted row; here the
 * inner controls stay real controls and the card gives up its tag.
 */
function chatItem(chat) {
  const actions = [];
  const action = (name, label, act) => el('button', {
    class: 'chat-item__action',
    type: 'button',
    title: label,
    onclick: (event) => {
      event.stopPropagation();
      emit('ui:chat-action', { id: chat.id, action: act });
    },
  }, icon(name, 'icon--sm'));

  if (chat.pinned) actions.push(action('pin', 'Unpin', 'unpin'));
  actions.push(chat.muted
    ? action('bell-off', 'Unmute', 'unmute')
    : action('bell', 'Mute', 'mute'));
  actions.push(chat.archived
    ? action('archive-out', 'Move to the main list', 'unarchive')
    : action('archive', 'Archive', 'archive'));

  const head = el('div', { class: 'chat-item__head' },
    icon(kindIcon(chat.kind), 'chat-item__kind'),
    chat.premium ? icon('crown', 'chat-item__kind') : null,
    el('span', { class: 'chat-item__title', textContent: chat.title || '(no title)' }),
    el('span', { class: 'chat-item__flags' }, actions),
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
    avatar(chat),
    el('span', { class: 'chat-item__text' }, preview),
    meta,
  );

  const open = () => setActiveChat(chat.id);
  return el('div', {
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
    role: 'button',
    tabIndex: 0,
    dataset: { chatId: String(chat.id) },
    onclick: open,
    onkeydown: (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        open();
      }
    },
  }, head, body);
}

/** Real photo when it is on disk, the inline blur while it is not. */
function avatar(chat) {
  const box = el('span', {
    class: `avatar chat-item__avatar${chat.deleted ? ' is-deleted' : ''}`,
  });
  if (chat.avatar) {
    box.append(el('img', { class: 'avatar__img', src: chat.avatar, alt: '' }));
  } else if (chat.avatarThumb) {
    box.append(el('img', { class: 'avatar__img is-blur', src: chat.avatarThumb, alt: '' }));
  } else {
    box.textContent = chat.deleted ? '×' : initial(chat.title);
  }
  return box;
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
