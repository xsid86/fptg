import { el, clear } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { icon, kindIcon } from '../util/icons.js';
import { listTime, countLabel, initial } from '../util/format.js';
import { closeMenu } from '../util/menu.js';
import { customEmojiNode } from '../util/emoji.js';
import { renderRichText } from '../util/entities.js';

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
  const action = (name, label, act) => el('button', {
    class: 'chat-item__action',
    type: 'button',
    title: label,
    onclick: (event) => {
      event.stopPropagation();
      emit('ui:chat-action', { id: chat.id, action: act });
    },
  }, icon(name, 'icon--sm'));

  // Saved Messages drops mute and archive for the same reason the
  // native card drops them: you cannot mute yourself, and offering to
  // file your own notes away from a one-pixel icon is not worth it.
  const isSelf = chat.kind === 'self';
  const actions = [];
  if (!isSelf) {
    actions.push(chat.archived
      ? action('archive-out', 'Move to the main list', 'unarchive')
      : action('archive', 'Archive', 'archive'));
  }
  // Pinning always addresses the main list - toggleChatIsPinned has no
  // other list to aim at - so a chat sitting in the archive has no pin
  // to toggle, and the slot is left out rather than shown dead.
  if (!chat.archived) {
    actions.push(chat.pinned
      ? action('pin-off', 'Unpin', 'unpin')
      : action('pin', 'Pin', 'pin'));
  }
  if (!isSelf) {
    actions.push(chat.muted
      ? action('bell-off', 'Unmute', 'unmute')
      : action('bell', 'Mute', 'mute'));
  }

  // Header order, the same one the native card paints: chat type,
  // premium mark, name, read receipt, time, then archive / pin / mute.
  const head = el('div', { class: 'chat-item__head' },
    icon(kindIcon(chat.kind), 'chat-item__kind'),
    chat.premium ? icon('crown', 'chat-item__premium') : null,
    el('span', { class: 'chat-item__title', textContent: chat.title || '(no title)' }),
    // The premium emoji status, which belongs to the name rather than
    // to the row: Telegram shows it right after the title, and it is
    // the one thing a premium account can put there.
    chat.emojiStatus ? customEmojiNode(chat.emojiStatus, 'emoji--status') : null,
    receipt(chat),
    el('span', { class: 'chat-item__time u-tabular', textContent: listTime(chat.date) }),
    el('span', { class: 'chat-item__flags' }, actions),
  );

  const preview = el('div', { class: 'chat-item__preview' });
  if (chat.outgoing) preview.append(el('span', { class: 'chat-item__me', textContent: 'You: ' }));
  // Through the same cutter the message text uses: the server sends the
  // custom-emoji spans of this line in the shape of entities, with the
  // same UTF-8 byte offsets, so there is one implementation of "cut a
  // string at byte offsets and put elements in the gaps".
  preview.append(renderRichText(chat.preview || '', chat.previewGlyphs ?? []));

  // The second line is always emitted, even with neither a folder nor
  // an unread count: it is what keeps every card the same height,
  // which is how the native row gets its constant height too (its
  // content box is sized from the avatar, not from what is in it).
  // The folder button is always here, with or without a folder: it is
  // the only way to assign one, so leaving it off the chats that have
  // none would hide it from exactly the rows that need it. The native
  // row paints a "no folder" chip for the same reason.
  //
  // Opening the menu needs the account's folder list, which is a round
  // trip - so the click is reported and main.js does the asking, the
  // same division every other action in this file follows.
  const folder = el('button', {
    class: `chip chat-item__folder${chat.folder ? '' : ' chat-item__folder--none'}`,
    type: 'button',
    title: chat.folder ? `Folder: ${chat.folder}` : 'Put this chat in a folder',
    onclick: (event) => {
      event.stopPropagation();
      emit('ui:folder-menu', { id: chat.id, anchor: event.currentTarget });
    },
  }, el('span', { textContent: chat.folder || 'no folder' }));

  const meta = el('div', { class: 'chat-item__meta' },
    folder,
    chat.unread > 0
      ? el('span', {
          class: `badge${chat.muted ? ' badge--muted' : ''}`,
          textContent: countLabel(chat.unread),
        })
      : null,
  );

  const body = el('div', { class: 'chat-item__body' },
    avatar(chat),
    el('div', { class: 'chat-item__text' }, preview, meta),
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

/**
 * The delivery tick for the row's own last message. Outgoing only -
 * the server sends '' for anything else, and then the slot is simply
 * absent rather than reserved and blank.
 */
const RECEIPTS = {
  pending: ['clock', 'Sending'],
  failed: ['alert', 'Failed to send'],
  sent: ['check', 'Sent'],
  read: ['check-double', 'Read'],
};

function receipt(chat) {
  const spec = RECEIPTS[chat.receipt];
  if (!spec) return null;
  const [name, label] = spec;
  return el('span', {
    class: `chat-item__receipt is-${chat.receipt}`,
    title: label,
  }, icon(name, 'icon--sm'));
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

// Which row the viewport is resting on, so a rebuild can put it back.
//
// A row rather than a pixel offset, and that is not belt-and-braces: the
// list is sorted by date, so a message arriving in a chat further down
// moves that chat to the top and shifts everything below it. Restoring
// scrollTop alone would then hold the pixel and slide the content. The
// native list anchors the same way and for the same reason (TMsgScroller
// keeps FRowIds alongside its offsets).
function scrollAnchor() {
  const edge = root.getBoundingClientRect().top;
  for (const node of root.children) {
    if (!node.dataset.chatId) continue;
    const box = node.getBoundingClientRect();
    if (box.bottom > edge) return { id: node.dataset.chatId, offset: box.top - edge };
  }
  return null;
}

function restoreScroll(anchor) {
  if (!anchor) return;
  const node = root.querySelector(`.chat-item[data-chat-id="${anchor.id}"]`);
  // The anchor chat can be gone (left, or filtered out of this list).
  // Nothing sensible to line up with, so leave the list where a fresh
  // render puts it.
  if (!node) return;
  root.scrollTop +=
    node.getBoundingClientRect().top - root.getBoundingClientRect().top - anchor.offset;
}

// The list this position belongs to. Moving between the main list and
// the archive is the one case where the old position means nothing.
let lastArchived = null;

function render() {
  if (!root) return;
  // The list is rebuilt wholesale, so an open menu would be left
  // pointing at a detached button - and the list rebuilds on any
  // incoming message, not just on something the user did.
  closeMenu();
  // Clearing the container resets its scrollTop, which threw the list
  // back to the top on every refresh - including the one that follows
  // changing a chat's folder.
  const keep = lastArchived === store.archived ? scrollAnchor() : null;
  lastArchived = store.archived;
  clear(root);
  const chats = store.chats;
  if (!chats.length) {
    root.append(el('div', { class: 'chat-list__empty', textContent: 'No chats here yet.' }));
    return;
  }
  const fragment = document.createDocumentFragment();
  for (const chat of chats) fragment.append(chatItem(chat));
  root.append(fragment);
  restoreScroll(keep);
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
