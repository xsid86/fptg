import { el, clear } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, onActiveChat } from '../core/store.js';
import { icon } from '../util/icons.js';
import { reanchorMenu, closeMenuIfDetached } from '../util/menu.js';
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
let threadBtn = null;
// A message the view owes the reader - see the ui:show-message
// handler. Null when there is nothing outstanding.
let wantMessage = null;

// id -> { node, hash }. Cleared when the chat changes.
const nodes = new Map();
let chatId = null;
let atBottom = true;
let wantScroll = null;          // 'pending' | 'settling' | null
// The reader has taken the scroller over, so the opening position is
// no longer ours to choose. Set by the gestures that can only be a
// person - never by our own scrollTop, which fires the same `scroll`
// event as a wheel does.
let userMoved = false;
let readTimer = null;
let lastState = null;
// items.length at which a fill request was last sent - see maybeFill.
let fillAskedAt = -1;
const pendingRead = new Set();
const seenMedia = new Set();

const READ_DEBOUNCE_MS = 500;   // same wait the native scroller uses
// How far above the "Unread messages" divider the view stops, so the
// last read message is still visible over it.
const UNREAD_AIR = 24;

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
    onclick: () => {
      takeOver();
      scrollToBottom();
    },
  }, icon('chevron-down'));
  root.parentElement.append(scrollBtn);

  // The way out of a comment thread, back to the post it hangs from.
  // Floating over the history rather than living in the bar above it:
  // the bar now describes the discussion group, and this button is
  // about leaving it.
  threadBtn = el('button', {
    class: 'history__to-post',
    type: 'button',
    title: 'Back to the post',
    hidden: true,
    onclick: () => emit('ui:thread-close'),
  }, icon('chevron-left'));
  root.parentElement.append(threadBtn);

  root.addEventListener('scroll', onScroll, { passive: true });
  // What ends the opening hold. All four are things only a person
  // does; a programmatic scrollTop does none of them.
  for (const name of ['wheel', 'touchstart', 'keydown', 'pointerdown']) {
    root.addEventListener(name, takeOver, { passive: true });
  }
  // A wider window can leave a history that used to fill the screen
  // too short again. The native frame checks the same thing from its
  // own Resize for the same reason.
  window.addEventListener('resize', () => maybeFill(lastState));
  // Put one message in view, wherever it is in the loaded range. Used
  // when leaving a comment thread: the reader came from that post and
  // expects to land back on it, and the model has already reloaded the
  // history around it.
  on('ui:show-message', (id) => {
    // Remembered, not done on the spot. Leaving a comment thread asks
    // for the post, and at that moment the post is not loaded yet: the
    // model has only been told to jump to it, and its page arrives a
    // beat later. So this is a standing wish, tried again after every
    // render until the message actually turns up.
    wantMessage = id;
    showWanted();
  });
  on('store:messages', render);
  onActiveChat(() => {
    // Whether a chat is OPEN, not whether its row happens to be in the
    // list on screen. The two came apart when the archive was shown
    // with an ordinary chat open, and treating a missing row as "no
    // chat" wiped the history on every refresh of that list.
    if (store.activeChatId === null) {
      renderEmpty('Pick a chat on the left', 'Its messages will show up here.');
    }
  });
  renderEmpty('Pick a chat on the left', 'Its messages will show up here.');
}

/**
 * Throws away the per-message node cache, so the next render rebuilds
 * everything.
 *
 * For changes that are real but are NOT in any message's payload - a
 * custom emoji's file arriving is the case this exists for. The cache
 * is keyed on the payload and would otherwise never notice.
 */
export function invalidateHistory() {
  nodes.clear();
  if (lastState) render(lastState);
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
  if (threadBtn) threadBtn.hidden = !state.thread;

  if (state.chatId !== chatId) {
    chatId = state.chatId;
    fillAskedAt = -1;
    // A destination belongs to the chat it was asked for. One that
    // never turned up must not stay pending here, or it would hold
    // the new chat's view still (see applyScroll).
    wantMessage = null;
    nodes.clear();
    seenMedia.clear();
    pendingRead.clear();
    clear(column);
    // A freshly opened chat starts where the native window starts it:
    // at the first unread message when there is one, at the bottom
    // otherwise. Nothing is positioned until unreadReady - until the
    // backfill search is over the boundary is not known yet.
    wantScroll = 'pending';
    userMoved = false;
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

  // A thread opens with the post itself, then a divider, then the
  // comments - the way the original client lays it out. Without the
  // post there is no way to quote a line of it, which is the whole
  // reason it is here rather than only in the channel.
  if (state.thread?.post) {
    // Keyed by the post, or a second thread would show the first
    // one's node back - separator() caches by key.
    desired.push(separator('thread-post:' + state.thread.post.id, () => {
      const box = el('div', { class: 'history__thread-post' });
      box.append(renderMessage(state.thread.post));
      return box;
    }));
    desired.push(separator('thread-start', () =>
      el('div', { class: 'history__date' },
        el('span', { textContent: 'Discussion starts here' }))));
  }

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
  // A message that was DELETED rather than rebuilt takes its node with
  // it, and a menu acting on a message that is gone has nothing left to
  // act on.
  closeMenuIfDetached();

  // Ready means the model has stopped hunting for the boundary - not
  // that it found it. It also says "ready" when it gives up, and one
  // of the ways it gives up is "a retry is already pending", after
  // which the missing pages can still arrive and the divider appear.
  // So this is where HOLDING the position starts, not where it is
  // decided once and for all: see applyScroll.
  if (wantScroll === 'pending' && state.unreadReady) wantScroll = 'settling';
  applyScroll(keepFromBottom);
  showWanted();
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
  // A box with no height cannot be "too short to fill", it simply is
  // not being shown - and asking on its behalf never ends, because
  // nothing that arrives can ever make zero bigger than zero. Every
  // page would be pulled in, one request per answer.
  if (root.clientHeight === 0) return;
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
  if (known) {
    reanchorMenu(known.node, node);
    known.node.replaceWith(node);
  }
  nodes.set(key, { node, hash, ids: group.map((m) => m.id) });
  return node;
}

function messageNode(msg) {
  const hash = JSON.stringify(msg);
  const known = nodes.get(msg.id);
  if (known && known.hash === hash) return known.node;

  const node = renderMessage(msg);
  // A context menu may be anchored to the node about to be thrown
  // away; it has to follow the message rather than be left pointing at
  // a detached element. See reanchorMenu.
  if (known) {
    reanchorMenu(known.node, node);
    known.node.replaceWith(node);
  }
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
/**
 * Where a freshly opened chat sits, and where it stays.
 *
 * The opening position is HELD rather than set once. Two things used
 * to move it afterwards, and both are ordinary:
 *
 *   * the divider can appear late. The model says "ready" when it
 *     stops hunting for the unread boundary, which includes giving up
 *     because a retry is pending - and that retry then brings the
 *     pages that cover the boundary after all.
 *   * whatever is below the fold can grow as it loads, and the
 *     ordinary anchor keeps the distance to the BOTTOM, so growth down
 *     there slides the reader down with it.
 *
 * Either way the chat ended up at its newest message with everything
 * on screen marked as read, which is the one thing opening at the
 * divider exists to prevent. Holding converges instead: whichever of
 * the two arrives, the next render puts the view back.
 *
 * The hold ends when the reader touches the scroller - not when a
 * scroll event arrives, because our own scrollTop raises one of those
 * too.
 */
function applyScroll(keepFromBottom) {
  if (wantScroll === 'pending') return;
  // A destination outranks both of the rules below, and it has to keep
  // outranking them: the media above it are sized from what TDLib said,
  // but link previews and stickers still settle after the fact, and
  // "keep the distance from the END" then slides the landing out of
  // view. Measured: a jump landed at 123px from the top and had drifted
  // to 146px ABOVE it by the time the pictures had drawn.
  if (wantMessage !== null) return;

  if (wantScroll === 'settling') {
    if (!userMoved) {
      const divider = separators.get('unread');
      if (divider?.isConnected) {
        // A little air above it, so it reads as the top of what is new
        // rather than as something clipped by the edge.
        scrollTo(divider.offsetTop - root.offsetTop - UNREAD_AIR);
      } else {
        scrollToBottom();
      }
      return;
    }
    wantScroll = null;
  }

  if (atBottom) scrollToBottom();
  else scrollTo(root.scrollHeight - keepFromBottom);
}

/** The reader has taken over; stop holding the opening position. */
function takeOver() {
  userMoved = true;
  // And stop holding the destination they were taken to: they are
  // reading from there now, and re-pinning it would fight the wheel.
  wantMessage = null;
}

/**
 * Moves the scroller AND writes down where it ended up.
 *
 * The second half is the point. A `scroll` event is dispatched in a
 * later task, so between setting scrollTop and hearing about it there
 * is a window in which atBottom still says whatever it said before -
 * and renders come thick and fast (every arriving message, every
 * download tick). Opening a chat sets atBottom = true, so a render
 * landing in that window took the "follow the newest" branch and threw
 * the reader from the unread divider straight to the end of the chat,
 * where everything on screen was then marked as read. Writing the
 * position down at the moment it is set leaves no such window.
 */
function scrollTo(top) {
  root.scrollTop = top;
  noteScrollPosition();
}

function noteScrollPosition() {
  const distance = root.scrollHeight - root.scrollTop - root.clientHeight;
  atBottom = distance < 40;
  if (scrollBtn) scrollBtn.hidden = atBottom;
}

/**
 * Puts the owed message in view, if it has arrived. Offsets rather
 * than scrollIntoView: the same arithmetic the unread divider uses,
 * and scrollIntoView needs a live viewport to centre into - there is
 * none while the window is not being drawn.
 */
function showWanted() {
  if (wantMessage === null) return;
  const entry = nodes.get(wantMessage);
  if (!entry?.node.isConnected) return;
  // NOT cleared here. The wish stands until the reader takes over -
  // see takeOver - because one correct placement is not enough while
  // the history is still growing into its final shape.
  // A deliberate destination outranks the opening position, which
  // would otherwise pull the view to the unread divider or the end.
  wantScroll = null;
  scrollTo(Math.max(0, entry.node.offsetTop - root.offsetTop - UNREAD_AIR));
}

function scrollToBottom() {
  root.scrollTop = root.scrollHeight;
  atBottom = true;
  if (scrollBtn) scrollBtn.hidden = true;
}

function onScroll() {
  noteScrollPosition();

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
    // A link preview's picture, for a message that is otherwise pure
    // text - so it is asked for here rather than in the media sweep
    // below, which only ever looks at msg.media.
    if (msg.link && msg.link.w > 0 && !msg.link.url_photo) {
      seenMedia.add(msg.id);
      emit('ui:ensure-media', { id: msg.id, what: 'link' });
      continue;
    }
    if (!msg.media) continue;
    if (msg.kind === 'photo' && !msg.media.url) {
      seenMedia.add(msg.id);
      emit('ui:ensure-media', { id: msg.id, what: 'preview' });
    }
  }
}
