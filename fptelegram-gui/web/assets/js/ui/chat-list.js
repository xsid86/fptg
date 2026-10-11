import { el, clear, reconcile } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { icon, kindIcon } from '../util/icons.js';
import { listTime, countLabel } from '../util/format.js';
import { closeMenuIfDetached } from '../util/menu.js';
import { customEmojiNode, customEmojiUrl } from '../util/emoji.js';
import { fillAvatar } from '../util/avatar.js';
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

function avatar(chat) {
  const box = el('span', { class: 'avatar chat-item__avatar' });
  fillAvatar(box, chat);
  return box;
}

// Which row the viewport is resting on, so a rebuild can put it back.
// key — data-атрибут строки: chatId у чатов, userId у контактов.
//
// A row rather than a pixel offset, and that is not belt-and-braces: the
// list is sorted by date, so a message arriving in a chat further down
// moves that chat to the top and shifts everything below it. Restoring
// scrollTop alone would then hold the pixel and slide the content. The
// native list anchors the same way and for the same reason (TMsgScroller
// keeps FRowIds alongside its offsets).
function scrollAnchor(key = 'chatId') {
  const edge = root.getBoundingClientRect().top;
  for (const node of root.children) {
    if (!node.dataset[key]) continue;
    const box = node.getBoundingClientRect();
    if (box.bottom > edge) return { key, id: node.dataset[key], offset: box.top - edge };
  }
  return null;
}

function restoreScroll(anchor) {
  if (!anchor) return;
  const attr = anchor.key === 'userId' ? 'data-user-id' : 'data-chat-id';
  const node = [...root.children].find((n) => n.getAttribute(attr) === anchor.id);
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

// What the box above the list is filtering by, lower-cased and
// trimmed, or '' for "show everything".
//
// It has to live HERE, and be applied while the list is built, rather
// than be a pass over the finished nodes afterwards. The list is
// rebuilt wholesale on every incoming message in any chat - which in a
// busy account is every few seconds - and a rebuild put every hidden
// row back while the box still had text in it. Measured: filtering to
// one row out of 113 held until the next render and then the whole
// list returned.
let needle = '';

/** Does this chat match what is typed in the filter box? */
function matches(chat) {
  if (!needle) return true;
  return (chat.title ?? '').toLowerCase().includes(needle)
    || (chat.preview ?? '').toLowerCase().includes(needle);
}

export function setChatFilter(text) {
  const next = text.trim().toLowerCase();
  if (next === needle) return;
  needle = next;
  render();
}

// The floating "back to the top" button. Lives beside the scroller,
// not in it - see mountChatList.
let topBtn = null;

// chat id -> { node, hash }. See render.
const rows = new Map();

// ------------------------------------------------- avatars on demand
// Аватарки просятся для строк, которые ВИДНЫ, — как у нативного списка,
// который зовёт EnsureAvatar из отрисовки ячейки. Раньше просились
// только первые 40 чатов при загрузке списка, и всё ниже так и стояло
// с размытым превью, пока чат не откроют.
//
// Строки, вошедшие в кадр, копятся и уходят одной пачкой (chats.avatars
// через main.js). Чат просится снова, только если его аватарка с тех
// пор поменялась (сменилось фото), — сервер и так ничего не делает
// дважды, но незачем спрашивать его на каждой прокрутке.
const AVATAR_BATCH_MS = 150;
const asked = new Map();          // chat id -> состояние аватарки, когда просили
const rowChat = new WeakMap();    // строка -> её чат
const pendingAvatars = new Set();
let avatarTimer = 0;
let seen = null;

const avatarState = (chat) =>
  `${chat.avatar || ''}|${chat.avatarThumb ? 't' : ''}|${chat.avatarAnim || ''}`;

function flushAvatars() {
  avatarTimer = 0;
  if (!pendingAvatars.size) return;
  emit('ui:avatars', [...pendingAvatars]);
  pendingAvatars.clear();
}

function seenObserver() {
  if (!seen) {
    seen = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const chat = rowChat.get(entry.target);
        if (!chat) continue;
        const state = avatarState(chat);
        if (asked.get(chat.id) === state) continue;
        asked.set(chat.id, state);
        pendingAvatars.add(chat.id);
      }
      if (pendingAvatars.size && !avatarTimer) {
        avatarTimer = setTimeout(flushAvatars, AVATAR_BATCH_MS);
      }
    }, { root, rootMargin: '200px 0px' });
  }
  return seen;
}

function rowNode(chat) {
  // Активность — не часть данных чата, но меняет строку (is-active): без
  // неё в ключе прежняя открытая строка оставалась подсвеченной, пока её
  // чат сам не менялся (после отправки файла — заметно).
  // Кастомные эмодзи строки (статус у имени, эмодзи в превью) — тоже в
  // ключе: файл догружается позже, чат при этом не меняется, и без
  // адресов в ключе строка держала запасной символ до клика по чату.
  const emojiIds = [chat.emojiStatus, ...(chat.previewGlyphs ?? []).map((g) => g?.customEmojiId)];
  const hash = JSON.stringify(chat) + (chat.id === store.activeChatId ? '|active' : '')
    + emojiIds.filter(Boolean).map(customEmojiUrl).join('|');
  const known = rows.get(chat.id);
  if (known && known.hash === hash) return known.node;
  if (known) seen?.unobserve(known.node);
  const node = chatItem(chat);
  rows.set(chat.id, { node, hash });
  rowChat.set(node, chat);
  seenObserver().observe(node);
  return node;
}

// --------------------------------------------------------- contacts
// Кнопка Contacts над списком: тот же контейнер показывает контакты
// аккаунта (contacts.list в мосте). Фильтр из поля поиска действует и
// здесь — по имени, имени пользователя и телефону. Клик — личка с
// человеком (ui:open-contact, main.js).
let contactsMode = false;
let contacts = [];

/** Показать контакты вместо чатов (или обновить уже показанные). */
export function showContacts(list) {
  if (!contactsMode) {
    for (const { node } of rows.values()) seen?.unobserve(node);
    rows.clear();
  }
  contactsMode = true;
  contacts = list ?? [];
  render();
}

/** Вернуть список чатов. */
export function hideContacts() {
  if (!contactsMode) return;
  contactsMode = false;
  contacts = [];
  contactsDrawn = '';
  if (root) clear(root);
  render();
}

export const contactsShown = () => contactsMode;

/** «В сети» / «был(а) …» по userStatus* (td_api.tl). */
export function statusText(c) {
  switch (c.status) {
    case 'userStatusOnline':
      return 'online';
    case 'userStatusOffline': {
      const when = new Date(c.wasOnline * 1000);
      const today = new Date();
      if (when.toDateString() === today.toDateString()) {
        return `last seen at ${when.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
      }
      return `last seen ${when.toLocaleDateString()}`;
    }
    case 'userStatusRecently':
      return 'last seen recently';
    case 'userStatusLastWeek':
      return 'last seen within a week';
    case 'userStatusLastMonth':
      return 'last seen within a month';
    default:
      return 'last seen a long time ago';
  }
}

function contactMatches(c) {
  if (!needle) return true;
  return [c.title, c.username, c.phone].some((v) => (v ?? '').toLowerCase().includes(needle));
}

// Что показано сейчас: список чатов перерисовывается на каждое событие
// где угодно, а строки контактов от этого не меняются — без проверки они
// пересоздавались бы, и аватарки мигали.
let contactsDrawn = '';

function renderContacts() {
  const key = JSON.stringify([needle, contacts]);
  if (key === contactsDrawn && root.childElementCount) return;
  contactsDrawn = key;
  // Список перечитывается целиком (смена папки, докачанные аватарки,
  // статусы) — без якоря clear() сбрасывал прокрутку к началу. Якорь —
  // строка, а не пиксели: онлайн-контакты стоят сверху и сдвигают
  // остальных, когда статус меняется.
  const keep = scrollAnchor('userId');
  const list = contacts.filter(contactMatches).sort((a, b) => {
    const ao = a.status === 'userStatusOnline' ? 0 : 1;
    const bo = b.status === 'userStatusOnline' ? 0 : 1;
    if (ao !== bo) return ao - bo;
    return (a.title || '').localeCompare(b.title || '');
  });
  if (!list.length) {
    clear(root).append(el('div', {
      class: 'chat-list__empty',
      textContent: needle ? `Nothing matches "${needle}"` : 'No contacts yet.',
    }));
    return;
  }
  clear(root).append(...list.map((c) => {
    const avatar = el('span', { class: `avatar avatar--md contact-row__avatar accent-${c.color}` });
    fillAvatar(avatar, { id: c.userId, title: c.title, avatar: c.avatar, avatarThumb: c.avatarThumb });
    // Чип папки лички — тот же, что у строки чата, и то же меню
    // (ui:folder-menu), текущая папка — с сервера. Только у тех, чья личка
    // стоит в списке (inList): без переписки её нет ни в одном, а в папку
    // Telegram берёт только чаты из списков — кнопка была бы мёртвой.
    const folder = c.inList !== true ? null : el('button', {
      class: `chip chat-item__folder contact-row__folder${c.folder ? '' : ' chat-item__folder--none'}`,
      type: 'button',
      title: c.folder ? `Folder: ${c.folder}` : 'Put this chat in a folder',
      onclick: (event) => {
        event.stopPropagation();
        emit('ui:folder-menu', {
          id: Number(c.userId), userId: c.userId, current: c.folderId ?? 0,
          anchor: event.currentTarget,
        });
      },
    }, el('span', { textContent: c.folder || 'no folder' }));
    // div с ролью кнопки, не <button>: внутри настоящая кнопка папки, а
    // кнопка в кнопке — невалидная разметка (см. chatItem).
    const open = () => emit('ui:open-contact', { userId: c.userId });
    return el('div', {
      class: `contact-row accent-${c.color}`,
      role: 'button',
      dataset: { userId: String(c.userId) },
      tabIndex: 0,
      onclick: open,
      onkeydown: (event) => {
        if (event.target !== event.currentTarget) return;
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          open();
        }
      },
    },
    avatar,
    el('span', { class: 'contact-row__text' },
      el('span', { class: 'contact-row__name' }, c.title || c.username || c.phone || '(no name)'),
      el('span', {
        class: `contact-row__status${c.status === 'userStatusOnline' ? ' is-online' : ''}`,
      }, statusText(c))),
    folder);
  }));
  restoreScroll(keep);
}

function render() {
  if (!root) return;
  if (contactsMode) {
    renderContacts();
    return;
  }
  const keep = lastArchived === store.archived ? scrollAnchor() : null;
  lastArchived = store.archived;
  // A row whose chat changed IS rebuilt, and this list's own folder
  // menu may have been anchored to it.
  //
  // Only that one, though. This used to be a plain closeMenu(), and
  // closeMenu() is global - so every refresh of the chat list also
  // shut whatever menu was open somewhere else, including the context
  // menu on a message. The list refreshes on any incoming message in
  // any chat, which is why that looked like the menu closing itself at
  // random moments. Detachment is the honest test: an anchor that has
  // just been thrown away is gone, a message's has not.
  closeMenuIfDetached();
  const chats = store.chats.filter(matches);
  if (!chats.length) {
    for (const { node } of rows.values()) seen?.unobserve(node);
    rows.clear();
    clear(root).append(el('div', {
      class: 'chat-list__empty',
      textContent: needle ? `Nothing matches "${needle}"` : 'No chats here yet.',
    }));
    noteScrollPosition();
    return;
  }
  // Rows are REUSED, not rebuilt. The list refreshes on a message in
  // any chat, and rebuilding every row each time threw away whatever
  // was living inside it - which is why the animated emoji beside a
  // name flickered: each refresh dropped its player and started a new
  // one, re-parsing the .tgs to show the same still frame again.
  //
  // Same trick as the history's messageNode: the payload is its own
  // hash, so a row is rebuilt exactly when the chat it draws changed.
  reconcile(root, chats.map(rowNode));
  // Rows for chats that have dropped off the list (a filter, a switch
  // to the archive) are of no further use.
  const listed = new Set(chats.map((c) => c.id));
  for (const [id, { node }] of [...rows]) {
    if (listed.has(id)) continue;
    seen?.unobserve(node);
    rows.delete(id);
  }
  restoreScroll(keep);
  noteScrollPosition();
}

// ------------------------------------------------------- to the top
// The history's "jump to the newest message", the other way up: the
// list is long, the chat you want is usually the freshest one, and
// scrolling back by hand after digging through it is the same chore
// the history button exists to save. Same look, same rule for when it
// is there - see .chat-list__to-top and the scroll-jump mixin.
const TOP_SLACK = 40;           // the same slack the history allows

function noteScrollPosition() {
  if (!topBtn) return;
  topBtn.hidden = root.scrollTop < TOP_SLACK;
}

function scrollToTop() {
  root.scrollTop = 0;
  noteScrollPosition();
}

export function mountChatList(node) {
  root = node;

  topBtn = el('button', {
    class: 'chat-list__to-top',
    type: 'button',
    title: 'Go to the top of the list',
    hidden: true,
    onclick: () => scrollToTop(),
  }, icon('chevron-down'));
  // Outside the scroller, in the box that holds it: a child of the
  // scroller would be laid out against its padding box and scroll away
  // with the rows. Same arrangement as the history's button.
  root.parentElement.append(topBtn);

  root.addEventListener('scroll', noteScrollPosition, { passive: true });

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
