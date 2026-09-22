import { el, clear } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { onActiveChat } from '../core/store.js';
import { icon } from '../util/icons.js';
import { dateLabel } from '../util/format.js';
import { renderMessage, renderAlbum } from './message.js';

// The message history.
//
// THE RULE THAT SHAPES THIS FILE: it does not re-render. A model change
// fires for every download-progress tick, so a full rebuild twenty
// times a second would throw away the scroll position, restart every
// <video>, and reset the play head of whatever <audio> was running.
// Instead each message keeps its node, and a node is rebuilt only when
// that message's own data actually changed.

let root = null;
let column = null;
let scrollBtn = null;

// id -> { node, hash }. Cleared when the chat changes.
const nodes = new Map();
let chatId = null;
let atBottom = true;
let wantScroll = null;          // 'bottom' | 'unread' | null
let readTimer = null;
let lastState = null;
// items.length at which a fill request was last sent - see maybeFill.
let fillAskedAt = -1;
const pendingRead = new Set();
const seenMedia = new Set();

const READ_DEBOUNCE_MS = 500;   // same wait the native scroller uses

// ---------------------------------------------------------- mounting
export function mountHistory(node) {
  root = node;
  column = el('div', { class: 'history__column' });
  root.append(column);

  scrollBtn = el('button', {
    class: 'history__to-bottom',
    type: 'button',
    title: 'Go to the newest message',
    hidden: true,
    onclick: () => scrollToBottom(),
  }, icon('chevron-down'));
  root.parentElement.append(scrollBtn);

  root.addEventListener('scroll', onScroll, { passive: true });
  // A wider window can leave a history that used to fill the screen
  // too short again. The native frame checks the same thing from its
  // own Resize for the same reason.
  window.addEventListener('resize', () => maybeFill(lastState));
  on('store:messages', render);
  onActiveChat((chat) => {
    if (!chat) renderEmpty('Pick a chat on the left', 'Its messages will show up here.');
  });
  renderEmpty('Pick a chat on the left', 'Its messages will show up here.');
}

function renderEmpty(title, note) {
  nodes.clear();
  clear(column);
  column.append(el('div', { class: 'workspace__empty' },
    icon('chat', 'icon--lg'),
    el('div', { textContent: title }),
    note ? el('div', { class: 'u-faint', textContent: note }) : null));
  if (scrollBtn) scrollBtn.hidden = true;
}

// ----------------------------------------------------------- render
function render(state) {
  if (!state) return;

  lastState = state;

  if (state.chatId !== chatId) {
    chatId = state.chatId;
    fillAskedAt = -1;
    nodes.clear();
    seenMedia.clear();
    pendingRead.clear();
    clear(column);
    // A freshly opened chat starts where the native window starts it:
    // at the first unread message when there is one, at the bottom
    // otherwise. The decision waits for unreadReady - until the
    // backfill search is over the boundary is not known yet, and
    // jumping twice looks like a glitch.
    wantScroll = 'pending';
    atBottom = true;
  }

  if (!state.items.length) {
    if (state.searchActive) {
      renderEmpty(
        state.searchQuery ? `Nothing matches "${state.searchQuery}"` : 'Nothing found',
        'No messages of this kind in this chat.',
      );
    } else if (state.loadingOlder) {
      renderEmpty('Loading…', null);
    } else {
      renderEmpty('No messages here yet', null);
    }
    return;
  }

  // Anchor: remember the distance from the bottom, because prepending
  // older pages changes scrollHeight and would otherwise slide the
  // reader up the page.
  const keepFromBottom = root.scrollHeight - root.scrollTop;

  const desired = [];
  let lastDay = null;
  let dividerPlaced = false;

  // Indexed rather than for..of because an album swallows the messages
  // that follow it, and the loop has to be able to skip them.
  for (let i = 0; i < state.items.length; i += 1) {
    const msg = state.items[i];
    const day = dateLabel(msg.date);
    if (day !== lastDay) {
      desired.push(separator(`day:${day}`, () =>
        el('div', { class: 'history__date' }, el('span', { textContent: day }))));
      lastDay = day;
    }

    if (!dividerPlaced && state.unreadCovered && state.unreadFrom
        && !msg.outgoing && msg.id > state.unreadFrom) {
      desired.push(separator('unread', () =>
        el('div', { class: 'history__unread', textContent: 'Unread messages' })));
      dividerPlaced = true;
    }

    // Messages of one album arrive as ordinary separate messages that
    // only share media_album_id, so the run has to be gathered here.
    // A run of one is left alone: a single photo is just a photo.
    if (msg.albumId) {
      let last = i;
      while (last + 1 < state.items.length
             && state.items[last + 1].albumId === msg.albumId) {
        last += 1;
      }
      if (last > i) {
        desired.push(albumNode(state.items.slice(i, last + 1)));
        i = last;
        continue;
      }
    }

    desired.push(messageNode(msg));
  }

  if (state.loadingOlder) {
    desired.unshift(separator('loading', () =>
      el('div', { class: 'history__loader' }, 'Loading older messages…')));
  }

  reconcile(column, desired);

  if (wantScroll === 'pending' && state.unreadReady) {
    wantScroll = (state.unreadCovered && state.unreadFrom && dividerPlaced)
      ? 'unread' : 'bottom';
  }
  applyScroll(keepFromBottom);
  requestVisibleMedia(state.items);
  maybeFill(state);
}

/**
 * Keeps asking for older pages while the history is too short to fill
 * the screen - the web half of TFrameHistory.MaybeLoadMore, and needed
 * for the same reason: getChatHistory routinely answers with fewer
 * messages than asked for ("fewer messages may be returned even if the
 * end has not been reached"), and on a cold cache that can be a single
 * message. Without this the user sees one message, nothing to scroll,
 * and therefore no near-the-top trigger to ever ask for more.
 *
 * The guard is the item count rather than a retry counter: a request
 * that brought nothing new leaves the count where it was, and asking
 * again at the same count could only bring nothing new again. A page
 * that did arrive changes it, which is exactly when another ask is
 * worth making. The model refuses a redundant LoadOlder anyway, so
 * this is about not filling the wire, not about correctness.
 */
function maybeFill(state) {
  if (!state || !state.items.length) return;
  if (state.loadingOlder || state.oldestLoaded) return;
  if (root.scrollHeight > root.clientHeight) {
    fillAskedAt = -1;
    return;
  }
  if (state.items.length === fillAskedAt) return;
  fillAskedAt = state.items.length;
  emit('ui:load-older');
}

/**
 * A message's node, rebuilt only when its own payload changed.
 * The hash is the payload itself: cheap enough at these sizes, and it
 * cannot disagree with what is on screen the way a hand-picked list of
 * fields eventually would.
 */
/**
 * Same caching as messageNode, keyed by the album instead of by one
 * message: the node is rebuilt only when something in the GROUP
 * changed, so a download finishing in one cell does not throw away the
 * others.
 */
function albumNode(group) {
  const key = `album:${group[0].albumId}`;
  const hash = JSON.stringify(group);
  const known = nodes.get(key);
  if (known && known.hash === hash) return known.node;

  const node = renderAlbum(group);
  if (known) known.node.replaceWith(node);
  nodes.set(key, { node, hash, ids: group.map((m) => m.id) });
  return node;
}

function messageNode(msg) {
  const hash = JSON.stringify(msg);
  const known = nodes.get(msg.id);
  if (known && known.hash === hash) return known.node;

  const node = renderMessage(msg);
  if (known) known.node.replaceWith(node);
  nodes.set(msg.id, { node, hash, ids: [msg.id] });
  return node;
}

const separators = new Map();
function separator(key, build) {
  if (!separators.has(key)) separators.set(key, build());
  return separators.get(key);
}

/**
 * Walks the wanted order against what is there, moving as little as
 * possible. Rebuilding the child list into a fragment and swapping it
 * in would be shorter and would also re-insert every node - which
 * restarts media elements, the very thing this file exists to avoid.
 */
function reconcile(parent, desired) {
  let i = 0;
  for (const node of desired) {
    const current = parent.childNodes[i];
    if (current !== node) parent.insertBefore(node, current ?? null);
    i += 1;
  }
  while (parent.childNodes.length > desired.length) {
    parent.lastChild.remove();
  }
}

// ----------------------------------------------------------- scroll
function applyScroll(keepFromBottom) {
  if (wantScroll === 'unread') {
    const divider = separators.get('unread');
    if (divider?.isConnected) {
      root.scrollTop = divider.offsetTop - root.offsetTop;
      wantScroll = null;
      return;
    }
  }
  if (wantScroll === 'bottom') {
    scrollToBottom();
    wantScroll = null;
    return;
  }
  if (wantScroll === 'pending') return;

  if (atBottom) scrollToBottom();
  else root.scrollTop = root.scrollHeight - keepFromBottom;
}

function scrollToBottom() {
  root.scrollTop = root.scrollHeight;
  atBottom = true;
  if (scrollBtn) scrollBtn.hidden = true;
}

function onScroll() {
  const distance = root.scrollHeight - root.scrollTop - root.clientHeight;
  atBottom = distance < 40;
  if (scrollBtn) scrollBtn.hidden = atBottom;

  // Near the top: ask for another page. The model ignores the request
  // when it is already loading or the history is exhausted, so there is
  // no need to track either of those here.
  if (root.scrollTop < 400) emit('ui:load-older');

  collectRead();
}

// ------------------------------------------------------- read marks
/**
 * Marks what is actually on screen as read, once the scrolling stops.
 * Debounced for the same reason the native scroller debounces it: a
 * flick of the wheel would otherwise fire a request per frame.
 */
function collectRead() {
  const top = root.scrollTop;
  const bottom = top + root.clientHeight;
  // Whatever the map is keyed by, what goes out are the MESSAGE ids the
  // node stands for - one for a message, all of them for an album.
  for (const entry of nodes.values()) {
    const node = entry.node;
    if (!node.isConnected) continue;
    if (node.classList.contains('message--outgoing')) continue;
    const y = node.offsetTop - root.offsetTop;
    if (y + node.offsetHeight >= top && y <= bottom) {
      for (const id of entry.ids) pendingRead.add(id);
    }
  }
  clearTimeout(readTimer);
  readTimer = setTimeout(() => {
    if (!pendingRead.size) return;
    emit('ui:mark-read', [...pendingRead]);
    pendingRead.clear();
  }, READ_DEBOUNCE_MS);
}

/**
 * Pulls in the previews for rows that are on screen - the web half of
 * what the native window does from its layout pass. Asked once per
 * message: the model is idempotent about it, but a request per render
 * would still be noise on the wire.
 */
function requestVisibleMedia(items) {
  for (const msg of items) {
    if (seenMedia.has(msg.id)) continue;
    if (!msg.media) continue;
    if (msg.kind === 'photo' && !msg.media.url) {
      seenMedia.add(msg.id);
      emit('ui:ensure-media', { id: msg.id, what: 'preview' });
    }
  }
}
