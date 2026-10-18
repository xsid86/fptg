import { el, clear } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { call } from '../core/net.js';
import { setActiveChat } from '../core/store.js';
import { fillAvatar } from '../util/avatar.js';
import { icon } from '../util/icons.js';

// Search above the chat list — as in Telegram Desktop.
//
// Focus in the field changes the side panel's look: instead of the list — a
// search panel with the Chats / Channels / Apps / Posts tabs. An empty
// field — the tab's "home" view (search.home): frequent ones as a strip
// that scrolls sideways ("All" expands it into a grid), below them the
// recent ones (Chats; Clear and a cross on a row), recommended channels or
// popular apps. A query (search.query) — known chats, public ones and
// messages ("Show more" — the next page, search.messages).
//
// Posts — search across all public channels: a few queries a day for free,
// then for stars. It searches only on a press (Search or Enter); a paid one
// — only with a separate button with the price, Enter does not start it.
//
// The up/down arrows in the field walk the rows and the strip, Enter opens.
//
// The panel is open until it is closed: with the "×" button in the field or
// Escape. Choosing a result (a chat, a message, an app) opens it on the
// right, and the panel stays — one can open the next. In Contacts mode the field still filters contacts (main.js) —
// the panel does not open then.

const TABS = [
  { id: 'chats', label: 'Chats' },
  { id: 'channels', label: 'Channels' },
  { id: 'apps', label: 'Apps' },
  { id: 'posts', label: 'Posts' },
];
// The typing pause before a query: each one is a search on Telegram.
const DEBOUNCE_MS = 250;
// The server downloads avatars not yet on disk on chats.avatars. Ready ones
// are picked up on the srv:chats signal (chats.rows — only these rows) and
// go into place without redrawing the panel; the pause — so a batch of
// downloads gives one request.
const AVATAR_REFRESH_MS = 600;
const KIND_LABEL = {
  channel: 'channel', group: 'group', bot: 'bot', private: 'private chat',
  self: 'saved messages', secret: 'secret chat',
};

let input = null;
let closeBtn = null;
let panel = null;
let body = null;
let tabsBox = null;
let host = null;
let opts = {};
let tab = 'chats';
let topExpanded = false;
let active = false;
let seq = 0;
let timer = 0;
let avatarTimer = 0;
// chat id -> its avatars in the panel, and those still without a picture.
let boxes = new Map();
const missing = new Set();
// The item chosen with the arrows (an index among .search__row and .search__peer).
let cursor = -1;
// The Posts tab: the current query's limits and what was found.
let posts = null;

const query = () => input.value.trim();

function open() {
  if (active || opts.disabled?.()) return;
  active = true;
  host.classList.add('is-searching');
  closeBtn.hidden = false;
  panel.hidden = false;
  load();
}

function close() {
  if (!active) return;
  active = false;
  clearTimeout(timer);
  seq += 1;
  host.classList.remove('is-searching');
  panel.hidden = true;
  closeBtn.hidden = true;
  topExpanded = false;
}

/** Leave search completely: the field empty, focus away. */
function exit() {
  input.value = '';
  close();
  input.blur();
}

function setTab(id) {
  if (tab === id) return;
  tab = id;
  posts = null;
  topExpanded = false;
  for (const b of tabsBox.children) {
    const on = b.dataset.tab === tab;
    b.classList.toggle('is-active', on);
    b.setAttribute('aria-selected', String(on));
  }
  load();
}

async function load() {
  const my = ++seq;
  const q = query();
  cursor = -1;
  if (tab === 'posts') {
    loadPostLimits(my, q);
    return;
  }
  let answer;
  try {
    answer = q
      ? await call('search.query', { tab, query: q })
      : await call('search.home', { tab });
  } catch (err) {
    if (my === seq) renderError(err);
    return;
  }
  if (my !== seq || !active) return;
  if (q) renderResults(answer, q);
  else renderHome(answer);
  askAvatars(answer);
}

// ------------------------------------------------------------ Posts

async function loadPostLimits(my, q) {
  let limits;
  try {
    limits = await call('search.postLimits', { query: q });
  } catch (err) {
    if (my === seq) renderError(err);
    return;
  }
  if (my !== seq || !active) return;
  posts = { query: q, limits, items: [], next: '', searched: false };
  renderPosts();
}

/** Whether searching this query is free right now. */
const postsFree = (l) => l.currentFree || (l.remainingFree > 0 && !l.nextFreeIn);

async function searchPosts({ paid = false, more = false } = {}) {
  if (!posts?.query) return;
  const my = ++seq;
  const stars = paid ? posts.limits.stars : 0;
  let answer;
  try {
    answer = await call('search.posts', {
      query: posts.query, offset: more ? posts.next : '', stars,
    });
  } catch (err) {
    if (my === seq) renderError(err);
    return;
  }
  if (my !== seq || !active) return;
  posts.items = more ? posts.items.concat(answer.messages ?? []) : (answer.messages ?? []);
  posts.next = answer.next ?? '';
  posts.limits = answer.limits ?? posts.limits;
  posts.exceeded = answer.exceeded;
  posts.searched = true;
  renderPosts();
  askAvatars({ messages: answer.messages });
}

function limitsText(l) {
  const parts = [`${l.remainingFree} of ${l.dailyFree} free searches left today`];
  if (l.nextFreeIn > 0) {
    const h = Math.floor(l.nextFreeIn / 3600);
    const m = Math.ceil((l.nextFreeIn % 3600) / 60);
    parts.push(`next free one in ${h ? `${h} h ` : ''}${m} min`);
  }
  return parts.join(' · ');
}

function renderPosts() {
  const p = posts;
  const head = el('div', { class: 'search__posts-head' },
    el('p', { class: 'search__posts-info' },
      p.query ? limitsText(p.limits) : 'Search posts in all public channels.'));
  if (p.query && !p.searched) {
    const free = postsFree(p.limits);
    head.append(free
      ? el('button', {
        class: 'btn btn--primary search__posts-go', type: 'button', onmousedown: keepFocus,
        onclick: () => searchPosts(),
      }, 'Search')
      : el('button', {
        class: 'btn btn--primary search__posts-go', type: 'button', onmousedown: keepFocus,
        onclick: () => searchPosts({ paid: true }),
      }, `Search for ${p.limits.stars} ⭐`));
  }
  const parts = [head];
  if (p.searched) {
    parts.push(p.items.length
      ? section('Posts', null, el('div', { class: 'search__rows' }, ...p.items.map(messageRow)),
        p.next ? moreButton(() => searchPosts({ more: true })) : null)
      : el('p', { class: 'search__empty' }, p.exceeded ? 'The search limit is reached' : 'No posts found'));
  }
  clear(body).append(...parts);
}

// ------------------------------------------------------------ view

function section(title, action, ...children) {
  return el('section', { class: 'search__section' },
    el('header', { class: 'search__section-head' },
      el('span', { class: 'search__section-title' }, title),
      action),
    ...children);
}

const headButton = (label, onclick) => el('button', {
  class: 'search__head-btn', type: 'button', onmousedown: keepFocus, onclick,
}, label);

// The panel's buttons do not take focus from the field: otherwise blur
// would close the panel before the click.
function keepFocus(event) {
  event.preventDefault();
}

function avatarFor(item, cls) {
  const box = el('span', { class: `avatar ${cls} accent-${item.color || 'a5'}` });
  // Chats — by id, so an avatar that finished downloading goes into place.
  if (item.id) {
    if (!boxes.has(item.id)) boxes.set(item.id, new Set());
    boxes.get(item.id).add(box);
  }
  fillAvatar(box, {
    id: item.id ?? item.userId,
    title: item.title ?? item.name ?? '?',
    avatar: item.avatar || '',
    avatarThumb: item.avatarThumb || '',
  });
  return box;
}

/** A chat in the strip: the avatar and a short name. */
function peer(chat) {
  return el('button', {
    class: 'search__peer', type: 'button', title: chat.title,
    onmousedown: keepFocus, onclick: () => openChat(chat),
  }, avatarFor(chat, 'search__peer-avatar'),
  el('span', { class: 'search__peer-name' }, firstName(chat.title)));
}

const firstName = (title = '') => title.split(/\s+/)[0] || title;

/** A chat row: the avatar, the title, the kind. */
function chatRow(chat, { removable = false } = {}) {
  const row = el('div', { class: 'search__row', role: 'button', tabindex: '-1' },
    avatarFor(chat, 'search__row-avatar'),
    el('span', { class: 'search__row-text' },
      el('span', { class: 'search__row-title' }, chat.title || 'Chat'),
      el('span', { class: 'search__row-sub' }, KIND_LABEL[chat.kind] ?? '')));
  row.addEventListener('mousedown', keepFocus);
  row.addEventListener('click', () => openChat(chat));
  if (removable) {
    row.append(el('button', {
      class: 'btn btn--icon search__row-remove', type: 'button', title: 'Remove from recent',
      onmousedown: keepFocus,
      onclick: (event) => {
        event.stopPropagation();
        call('search.recent', { op: 'remove', id: chat.id }).then(load).catch(report);
      },
    }, '×'));
  }
  return row;
}

/** A user row (popular apps — bots). */
function userRow(user) {
  const row = el('div', { class: 'search__row', role: 'button', tabindex: '-1' },
    avatarFor(user, 'search__row-avatar'),
    el('span', { class: 'search__row-text' },
      el('span', { class: 'search__row-title' }, user.name || 'Bot'),
      el('span', { class: 'search__row-sub' }, user.username ? `@${user.username}` : '')));
  row.addEventListener('mousedown', keepFocus);
  row.addEventListener('click', () => {
    emit('ui:open-contact', { userId: user.userId });
  });
  return row;
}

/** A found message: the chat, the date, "sender: text". */
function messageRow(m) {
  const date = new Date(m.date * 1000);
  const sameDay = date.toDateString() === new Date().toDateString();
  const when = sameDay
    ? date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    : date.toLocaleDateString([], { day: 'numeric', month: 'short' });
  const who = m.outgoing ? 'You' : (m.chat.kind === 'group' ? m.sender : '');
  const row = el('div', { class: 'search__row search__row--message', role: 'button', tabindex: '-1' },
    avatarFor(m.chat, 'search__row-avatar'),
    el('span', { class: 'search__row-text' },
      el('span', { class: 'search__row-line' },
        el('span', { class: 'search__row-title' }, m.chat.title || 'Chat'),
        el('span', { class: 'search__row-date' }, when)),
      el('span', { class: 'search__row-sub' },
        who ? el('span', { class: 'search__row-who' }, `${who}: `) : null,
        m.text || '')));
  row.addEventListener('mousedown', keepFocus);
  row.addEventListener('click', () => {
    call('search.recent', { op: 'add', id: m.chat.id }).catch(() => {});
    emit('ui:open-source', { chatId: m.chat.id, messageId: m.id });
  });
  return row;
}

function strip(title, chats) {
  if (!chats?.length) return null;
  const list = el('div', { class: `search__strip${topExpanded ? ' is-expanded' : ''}` },
    ...chats.map(peer));
  // The mouse wheel scrolls the strip sideways — as in Desktop.
  list.addEventListener('wheel', (event) => {
    if (topExpanded || Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
    list.scrollLeft += event.deltaY;
    event.preventDefault();
  }, { passive: false });
  return section(title, headButton(topExpanded ? 'Less' : 'All', () => {
    topExpanded = !topExpanded;
    list.classList.toggle('is-expanded', topExpanded);
    list.scrollLeft = 0;
  }), list);
}

const rows = (title, items, make, action = null) => (items?.length
  ? section(title, action, el('div', { class: 'search__rows' }, ...items.map(make)))
  : null);

function renderHome(a) {
  const parts = [];
  if (tab === 'chats') {
    parts.push(strip('Frequent contacts', a.top));
    parts.push(rows('Recent', a.recent, (c) => chatRow(c, { removable: true }),
      a.recent?.length ? headButton('Clear', () => {
        call('search.recent', { op: 'clear' }).then(load).catch(report);
      }) : null));
  } else if (tab === 'channels') {
    parts.push(strip('Frequent channels', a.top));
    parts.push(rows('Recommended channels', a.recommended, (c) => chatRow(c)));
  } else {
    parts.push(strip('Frequent apps', a.top));
    parts.push(rows('Popular apps', a.popular, userRow));
  }
  show(parts, 'Nothing here yet');
}

function renderResults(a, q) {
  let messages = null;
  if (a.messages?.length) {
    const list = el('div', { class: 'search__rows' }, ...a.messages.map(messageRow));
    let next = a.messagesNext ?? '';
    const more = moreButton(async () => {
      const my = seq;
      let page;
      try {
        page = await call('search.messages', { tab, query: q, offset: next });
      } catch (err) {
        report(err);
        return;
      }
      if (my !== seq || !active) return;
      list.append(...(page.messages ?? []).map(messageRow));
      next = page.messagesNext ?? '';
      more.hidden = !next;
      askAvatars({ messages: page.messages });
    });
    more.hidden = !next;
    messages = section('Messages', null, list, more);
  }
  show([
    rows(tab === 'channels' ? 'Channels' : tab === 'apps' ? 'Apps' : 'Chats', a.chats, (c) => chatRow(c)),
    rows('Global search', a.global, (c) => chatRow(c)),
    messages,
  ], 'No results');
}

const moreButton = (onclick) => el('button', {
  class: 'search__more', type: 'button', onmousedown: keepFocus, onclick,
}, 'Show more');

// ------------------------------------------------------------ arrows

const pickable = () => [...body.querySelectorAll('.search__row, .search__peer')];

function moveCursor(delta) {
  const items = pickable();
  if (!items.length) return;
  items[cursor]?.classList.remove('is-selected');
  cursor = cursor < 0 ? (delta > 0 ? 0 : items.length - 1)
    : (cursor + delta + items.length) % items.length;
  items[cursor].classList.add('is-selected');
  items[cursor].scrollIntoView({ block: 'nearest', inline: 'nearest' });
}

function show(parts, emptyText) {
  const real = parts.filter(Boolean);
  // Old avatars go away together with the previous view.
  boxes = new Map([...boxes].map(([id, set]) => [id, new Set([...set].filter((b) => real.some((p) => p.contains(b))))]));
  clear(body).append(...(real.length ? real : [el('p', { class: 'search__empty' }, emptyText)]));
}

function renderError(err) {
  clear(body).append(el('p', { class: 'search__empty' }, err?.message || 'Search failed'));
}

function report(err) {
  emit('ui:error', err instanceof Error ? err.message : String(err));
}

/** Open a chat from search: it goes into the recent ones. */
function openChat(chat) {
  call('search.recent', { op: 'add', id: chat.id }).catch(() => {});
  opts.beforeOpen?.();
  setActiveChat(chat.id);
}

/** Avatars not here yet: the server downloads them (chats.avatars). */
function askAvatars(answer) {
  const ids = [];
  for (const list of Object.values(answer ?? {})) {
    if (!Array.isArray(list)) continue;
    for (const item of list) {
      const chat = item.chat ?? item;
      if (chat.id && !chat.avatar && !missing.has(chat.id)) {
        missing.add(chat.id);
        ids.push(chat.id);
      }
    }
  }
  if (ids.length) call('chats.avatars', { ids }).catch(() => {});
}

/** Those downloaded since — into place (on the srv:chats signal). */
async function refreshAvatars() {
  if (!active || !missing.size) return;
  let answer;
  try {
    answer = await call('chats.rows', { ids: [...missing] });
  } catch {
    return;
  }
  for (const row of answer?.items ?? []) {
    if (!row.avatar) continue;
    missing.delete(row.id);
    for (const box of boxes.get(row.id) ?? []) {
      if (box.isConnected) fillAvatar(box, row);
    }
  }
}

/**
 * input — the field above the list; hostNode — the side panel (it gets the
 * is-searching class: CSS hides the list); bodyNode — where the panel goes.
 * options: { disabled(): do not open (Contacts mode), beforeOpen() }.
 */
export function mountSearch(inputNode, hostNode, bodyNode, options = {}) {
  input = inputNode;
  host = hostNode;
  opts = options;
  tabsBox = el('div', { class: 'search__tabs', role: 'tablist' },
    ...TABS.map((t) => el('button', {
      class: `search__tab${t.id === tab ? ' is-active' : ''}`,
      type: 'button', role: 'tab', 'aria-selected': String(t.id === tab),
      dataset: { tab: t.id },
      onmousedown: keepFocus,
      onclick: () => setTab(t.id),
    }, t.label)));
  body = el('div', { class: 'search__body' });
  panel = el('div', { class: 'search', hidden: true }, tabsBox, body);
  bodyNode.append(panel);

  input.addEventListener('focus', open);
  // The field may have stayed focused (after search closes focus leaves,
  // but not always) — a click on it opens too.
  input.addEventListener('mousedown', open);
  input.addEventListener('input', () => {
    if (opts.disabled?.()) return;
    if (!active) open();
    clearTimeout(timer);
    timer = setTimeout(load, DEBOUNCE_MS);
  });
  input.addEventListener('keydown', (event) => {
    if (!active) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      exit();
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      moveCursor(event.key === 'ArrowDown' ? 1 : -1);
    } else if (event.key === 'Enter') {
      const item = pickable()[cursor];
      if (item) {
        event.preventDefault();
        item.click();
      } else if (tab === 'posts' && posts?.query && !posts.searched && postsFree(posts.limits)) {
        // Only a free one: a paid one — with the price button.
        event.preventDefault();
        searchPosts();
      }
    }
  });
  // Close search — a button of its own in the field: type=search has a
  // cross only while text is typed, and the panel can be open with an empty field too.
  closeBtn = el('button', {
    class: 'btn btn--icon search__close', type: 'button', title: 'Close search', hidden: true,
    onmousedown: keepFocus,
    onclick: exit,
  }, icon('close'),
  el('span', { class: 'u-sr-only' }, 'Close search'));
  input.after(closeBtn);
  // The Archive / Contacts tabs above the list are not search.
  on('ui:search-close', exit);
  // The server reports changes in chats — including downloaded avatars.
  on('srv:chats', () => {
    if (!active || !missing.size) return;
    clearTimeout(avatarTimer);
    avatarTimer = setTimeout(refreshAvatars, AVATAR_REFRESH_MS);
  });
}
