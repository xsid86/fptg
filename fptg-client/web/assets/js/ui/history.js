import { el, clear, reconcile } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, onActiveChat } from '../core/store.js';
import { icon } from '../util/icons.js';
import { reanchorMenu, closeMenuIfDetached } from '../util/menu.js';
import { dateLabel } from '../util/format.js';
import { updateFloatDate as updateFloatDateIn } from '../util/floatdate.js';
import { renderMessage, renderMessageReusing, renderAlbum } from './message.js';
import { greetingNode } from './greeting.js';
import { channelAds, adCard } from './sponsored.js';

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
let floatDate = null;
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

// ------------------------------------------------------ the window
//
// Only a window of messages around the reader is built as real nodes;
// the rest is two gaps as tall as what they stand for. Measured before
// this existed: 628 messages meant 17241 DOM elements, every one of
// them reconciled on each of the model's changes (they come several a
// second while media download), and collectRead read the position of
// every one of them on every scroll event.
//
// The window is generous on purpose. The reader sees a dozen messages;
// the rest is what a flick of the wheel can cross before the next
// render catches up, so the gaps are never seen being filled in.
const WINDOW = 120;
// How close to the window's edge the reader may come before it moves.
const WINDOW_EDGE = 30;
// What a message that has never been built is assumed to be worth,
// until this chat has shown what its messages are really like. A fixed
// number is a poor guess: measured on a media-heavy channel the built
// messages averaged 329px against this, so the gap came out at a fifth
// of the height it stood for and the scrollbar described a chat five
// times shorter than the real one. So it is only the seed for an
// average of what has actually been measured here.
const GUESS_H = 72;

// id -> the height of the slot its node occupied, margins and any
// divider above it included (measured as the distance to the next
// message, so nothing between them is lost). NUMBERS ONLY: this is
// what the gaps are made of, and it must not keep a node alive.
const heights = new Map();
// Running total of the heights in that map, so the guess for the
// unbuilt ones is this chat's own average rather than a constant.
// Kept as a sum rather than recomputed: the map is walked once per
// render already, and that is enough.
let hSum = 0;
let hCount = 0;
// The half-open range of state.items currently built.
let winFrom = 0;
let winTo = 0;
// item index -> its node, for the built range only.
let winNodes = [];
// The message the reader is on, BY ID. Not by index: a page of older
// messages arrives at the FRONT of the list and moves every index
// along with it, so an index would quietly come to mean a different
// message - and the window would jump to it.
let anchorId = null;
// render() re-entered from the scroll handler would be a loop.
let framing = false;
// Whether the reader was at the newest end last time we looked, so
// COMING BACK to it can be told from sitting there - see onScroll.
let wasAtBottom = true;

// How long a history has to be before returning to its end is worth
// telling the server about. The server has the final say (it holds the
// history and knows what it is about to drop, and its own TRIM_AT is
// the one that counts); this only keeps the page from asking after
// every little chat. Kept in step with constants.pas deliberately -
// when the two disagreed, the page never asked and the trim looked
// broken.
const TRIM_AT = 100;

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

  // Дата дня, который сейчас наверху, — поверх истории, а не в ней. См.
  // updateFloatDate.
  floatDate = el('div', { class: 'history__float-date', hidden: true },
    el('span', { title: 'Go to the first message of this day' }));
  root.parentElement.append(floatDate);
  // Клик по дате — к первому сообщению этого дня (main.js, chat.dateJump).
  // В ветке комментариев — нет: getChatMessageByDate о ветках не знает.
  const jumpToDay = (date) => {
    if (!date || store.messages?.thread) return;
    takeOver();
    emit('ui:jump-date', Number(date));
  };
  floatDate.addEventListener('click', () => jumpToDay(floatDate.dataset.date));
  root.addEventListener('click', (event) => {
    const chip = event.target.closest('.history__date[data-date] > span');
    if (chip) jumpToDay(chip.parentElement.dataset.date);
  });

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
  // Реклама канала доехала (или ушла после жалобы) — ui/sponsored.js.
  on('ui:ads', () => render(lastState));
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

// Заглушка пустой истории. Запоминается, потому что сверка узлов в
// paint знает только узлы сообщений: пока фильтр ждал ответа, список был
// пуст и заглушка встала в колонку, а пришедшие результаты легли вокруг
// неё — «Nothing found» посреди найденного.
let emptyNode = null;

// ------------------------------------------------------- arrivals
// Новые сообщения въезжают снизу (класс is-arriving, blocks/_message.scss).
// Новое — то, чего в этом чате ещё не было и что новее самого свежего
// из показанного. Не новое: первая загрузка чата, подгрузка старых,
// виртуальное окно, перерисовка, поиск.
//
// known — id показанного в прошлый раз -> «своё и ещё отправляется»;
// null — в этом чате ещё ничего не показано (первый кадр не анимируется).
// Отправленное своё TDLib переименовывает (временный id -> настоящий):
// пропавшее «отправляется» гасит одно своё новое, иначе своё сообщение
// въезжало бы второй раз, когда дойдёт.
let known = null;
let newest = 0;
// Больше за один кадр — это не «пришло», а подгрузка страницы новых
// (после прыжка по дате или к сообщению).
const ARRIVE_MAX = 3;

function rememberShown(items) {
  known = new Map(items.map((m) => [m.id, Boolean(m.outgoing && m.receipt === 'pending')]));
  newest = items.reduce((max, m) => (m.id > max ? m.id : max), newest);
}

function arrivals(state) {
  const items = state.items;
  if (known === null || state.searchActive || wantScroll === 'pending') {
    if (state.searchActive) known = null;
    else rememberShown(items);
    return new Set();
  }
  const ids = new Set(items.map((m) => m.id));
  let renamed = 0;
  for (const [id, sending] of known) {
    if (sending && !ids.has(id)) renamed += 1;
  }
  const fresh = [];
  for (const m of items) {
    if (known.has(m.id) || m.id <= newest) continue;
    if (m.outgoing && renamed > 0) {
      renamed -= 1;
      continue;
    }
    fresh.push(m.id);
  }
  rememberShown(items);
  return fresh.length <= ARRIVE_MAX ? new Set(fresh) : new Set();
}

// Класс снимается, как только въезд кончился: иначе узел, выпавший из
// виртуального окна и вставленный обратно, въезжал бы снова (анимация
// CSS перезапускается при вставке). Прерванная — тоже.
function arrivedEnd(event) {
  if (event.target === event.currentTarget) event.currentTarget.classList.remove('is-arriving');
}

function markArriving(node) {
  node.classList.add('is-arriving');
  node.addEventListener('animationend', arrivedEnd);
  node.addEventListener('animationcancel', arrivedEnd);
}

function renderGreeting(id) {
  nodes.clear();
  clear(column);
  emptyNode = greetingNode(id);
  column.append(emptyNode);
  if (scrollBtn) scrollBtn.hidden = true;
}

function renderEmpty(title, note) {
  nodes.clear();
  clear(column);
  emptyNode = el('div', { class: 'workspace__empty' },
    icon('chat', 'icon--lg'),
    el('div', { textContent: title }),
    note ? el('div', { class: 'u-faint', textContent: note }) : null);
  column.append(emptyNode);
  if (scrollBtn) scrollBtn.hidden = true;
}

// ----------------------------------------------------------- render
/**
 * Renders, and says so while it does.
 *
 * Moving the scroller is how the window learns it has to move (see
 * reframe), and render moves the scroller itself - so without this it
 * would re-enter itself through its own scrolling.
 */
function render(state) {
  if (!state) return;
  framing = true;
  try {
    paint(state);
  } finally {
    framing = false;
  }
}

function paint(state) {
  lastState = state;
  if (threadBtn) threadBtn.hidden = !state.thread;
  // Свои сообщения справа, чужие слева (blocks/_message.scss) — кроме
  // ленты канала: там «свои» — все посты владельца, и разнос по сторонам
  // ничего не различал бы. Ветка комментариев — уже группа.
  // Строка открытого чата, а не поиск в списке: архивного канала или
  // канала, до которого дошли по пересылке, в списке может не быть.
  const chat = state.chat ?? store.activeChat;
  column.classList.toggle('is-channel', chat?.kind === 'channel' && !state.thread);

  if (state.chatId !== chatId) {
    chatId = state.chatId;
    fillAskedAt = -1;
    // A destination belongs to the chat it was asked for. One that
    // never turned up must not stay pending here, or it would hold
    // the new chat's view still (see applyScroll).
    wantMessage = null;
    nodes.clear();
    separators.clear();
    heights.clear();
    hSum = 0;
    hCount = 0;
    winFrom = 0;
    winTo = 0;
    winNodes = [];
    anchorId = null;
    known = null;
    newest = 0;
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
    wasAtBottom = true;
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
      // Пустой чат — приветствие, как у нативного клиента (ui/greeting.js).
      renderGreeting(state.chatId);
      // Первое сообщение в пустой чат — уже «пришло».
      known = new Map();
    }
    return;
  }
  if (emptyNode) {
    emptyNode.remove();
    emptyNode = null;
  }

  // Anchor: remember the distance from the bottom, because prepending
  // older pages changes scrollHeight and would otherwise slide the
  // reader up the page.
  const keepFromBottom = root.scrollHeight - root.scrollTop;

  const items = state.items;
  const [from, to] = windowFor(state);
  // What sits above the reader changes for three different reasons -
  // the window moves, a page of older messages arrives, or the gap is
  // simply re-reckoned because more heights are now known - and all
  // three would shove the view. Measured: 15000px of scrolling saw the
  // gap alone shrink by 7962px.
  //
  // So the view is pinned to a NODE rather than to any arithmetic:
  // whatever the layout turns out to be, put that node back where the
  // reader had it. Every render, not only when the window moves. Only
  // while the reader is in charge, though - the opening position and a
  // jump are deliberate placements and outrank this.
  const pinning = !atBottom && wantScroll === null && wantMessage === null;
  const pinNode = pinning
    ? (nodes.get(anchorId)?.node ?? winNodes[winFrom] ?? null)
    : null;
  const pinWas = pinNode?.isConnected ? pinNode.getBoundingClientRect().top : null;

  const desired = [];
  const slots = [];
  winNodes = [];
  let lastDay = null;
  let dividerPlaced = false;
  const adAt = adPlaces(state, chat);

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

  // Everything older than the window, as one gap.
  if (from > 0) desired.push(gapNode(sumHeights(items, 0, from)));

  // Indexed rather than for..of because an album swallows the messages
  // that follow it, and the loop has to be able to skip them.
  for (let i = from; i < to; i += 1) {
    const msg = items[i];
    const day = dateLabel(msg.date);
    if (day !== lastDay) {
      // data-day — по нему плавающая дата (updateFloatDate) отличает
      // дневные разделители от «Discussion starts here».
      // data-date — полночь этого дня (unix, по часам страницы): клик по
      // разделителю или плавающему ярлыку ведёт к первому сообщению дня.
      const midnight = new Date(msg.date * 1000);
      midnight.setHours(0, 0, 0, 0);
      const date = String(Math.floor(midnight.getTime() / 1000));
      desired.push(separator(`day:${date}`, () =>
        el('div', { class: 'history__date', dataset: { day, date } },
          el('span', { textContent: day, title: 'Go to the first message of this day' }))));
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
      while (last + 1 < to && items[last + 1].albumId === msg.albumId) {
        last += 1;
      }
      if (last > i) {
        const group = items.slice(i, last + 1);
        const node = albumNode(group);
        desired.push(node);
        slots.push({ node, ids: group.map((m) => m.id) });
        for (let k = i; k <= last; k += 1) winNodes[k] = node;
        for (let k = i; k <= last; k += 1) {
          if (adAt.has(k)) desired.push(adCard(adAt.get(k)));
        }
        i = last;
        continue;
      }
    }

    const node = messageNode(msg);
    desired.push(node);
    slots.push({ node, ids: [msg.id] });
    winNodes[i] = node;
    if (adAt.has(i)) desired.push(adCard(adAt.get(i)));
  }

  // And everything newer than it.
  if (to < items.length) desired.push(gapNode(sumHeights(items, to, items.length)));

  // Плашка нулевой высоты: в потоке места не занимает, надпись висит
  // поверх у верхнего края. Обычным блоком она появлялась и пропадала
  // на каждой подгрузке и дёргала всю колонку (заметнее всего в короткой
  // ветке комментариев, которая не прокручивается).
  if (state.loadingOlder) {
    desired.unshift(separator('loading', () =>
      el('div', { class: 'history__loader' },
        el('span', { class: 'history__loader-pill' }, 'Loading older messages…'))));
  }

  // До вставки: въезд начинается, когда узел попадает в документ.
  const fresh = arrivals(state);
  if (fresh.size) {
    for (const slot of slots) {
      if (slot.ids.some((id) => fresh.has(id))) markArriving(slot.node);
    }
  }

  reconcile(column, desired);
  winFrom = from;
  winTo = to;
  // Nodes the window has left behind. Dropping the ENTRY is the point:
  // holding a detached node in the map would keep alive the very thing
  // this window exists to let go of, and its pictures with it.
  for (const [key, entry] of nodes) {
    if (!entry.node.isConnected) nodes.delete(key);
  }
  measureSlots(slots);
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
  // Put the pinned node back where the reader had it. After
  // applyScroll, because this is the more exact answer to the same
  // question and it is measured against what actually happened.
  if (pinNode?.isConnected && pinWas !== null) {
    const drift = pinNode.getBoundingClientRect().top - pinWas;
    if (drift) {
      root.scrollTop += drift;
      noteScrollPosition();
    }
  }
  showWanted();
  requestVisibleMedia(items.slice(from, to));
  maybeFill(state);
}

/**
 * Где стоит реклама канала: индекс сообщения -> реклама после него.
 *
 * Первая — после последнего поста. messages_between > 0 разрешает
 * больше одной: каждая следующая — на столько сообщений выше
 * предыдущей; 0 — только одна (так в td_api.tl, sponsoredMessages).
 * Не в ветке комментариев и не в поиске — там нет «последнего поста».
 */
function adPlaces(state, chat) {
  const places = new Map();
  if (chat?.kind !== 'channel' || state.thread || state.searchActive) return places;
  const data = channelAds(state.chatId);
  if (!data) return places;
  const last = state.items.length - 1;
  data.items.forEach((ad, k) => {
    if (k > 0 && !(data.between > 0)) return;
    const at = last - k * (data.between || 0);
    if (at >= 0) places.set(at, ad);
  });
  return places;
}

/**
 * Which slice of the history to build, as [from, to).
 *
 * A short history is built whole - that is most chats, and it leaves
 * them working exactly as they did before any of this.
 */
function windowFor(state) {
  const n = state.items.length;
  if (n <= WINDOW) return [0, n];

  let centre;
  if (wantMessage !== null) {
    // A destination has to BE built, or it can never be shown.
    centre = state.items.findIndex((m) => m.id === wantMessage);
  } else if (wantScroll !== null && state.unreadCovered && state.unreadFrom) {
    // Opening at the unread divider: that is where the reader lands,
    // so that is where the window belongs.
    centre = state.items.findIndex((m) => !m.outgoing && m.id > state.unreadFrom);
  } else if (atBottom) {
    centre = n - 1;
  } else {
    centre = state.items.findIndex((m) => m.id === anchorId);
    // Not knowing where the reader is, is not a reason to move them.
    // Anywhere but here would be a guess; the middle of the window
    // they already have is the one answer that changes nothing.
    if (centre < 0) centre = winFrom + (WINDOW >> 1);
  }
  if (centre === undefined || centre < 0) centre = n - 1;

  let from = Math.max(0, Math.min(centre - (WINDOW >> 1), n - WINDOW));
  let to = Math.min(n, from + WINDOW);
  // An album is one node for a run of messages: a window cut through
  // the middle of one would build it short.
  while (from > 0 && state.items[from].albumId
         && state.items[from - 1].albumId === state.items[from].albumId) {
    from -= 1;
  }
  while (to < n && state.items[to - 1].albumId
         && state.items[to].albumId === state.items[to - 1].albumId) {
    to += 1;
  }
  return [from, to];
}

/** What the messages in [from, to) are worth, in pixels. */
function sumHeights(items, from, to) {
  let px = 0;
  for (let i = from; i < to; i += 1) {
    const h = heights.get(items[i].id);
    px += h === undefined ? guessHeight() : h;
  }
  return px;
}

/** What an unbuilt message is worth: this chat's average, once known. */
function guessHeight() {
  return hCount > 0 ? Math.round(hSum / hCount) : GUESS_H;
}

/**
 * The height of each built slot, taken as the distance to the next one
 * so that margins and any divider in between are counted exactly once,
 * by the message they sit above.
 */
function measureSlots(slots) {
  for (let k = 0; k < slots.length; k += 1) {
    const top = slots[k].node.offsetTop;
    const next = k + 1 < slots.length
      ? slots[k + 1].node.offsetTop
      : top + slots[k].node.offsetHeight;
    const h = next - top;
    if (h <= 0) continue;
    noteHeight(slots[k].ids[0], h);
    // An album is one node for several messages: the first of them
    // carries the height, the rest are worth nothing on their own.
    for (let j = 1; j < slots[k].ids.length; j += 1) noteHeight(slots[k].ids[j], 0);
  }
}

/**
 * Remembers one slot's height, keeping the running average honest when
 * a message is measured again after being rebuilt.
 *
 * The zeroes COUNT. An album is one node for several messages, so its
 * height sits on the first of them and its siblings are worth nothing
 * - and the average is applied per MESSAGE, to messages that have
 * never been built and may well turn out to be album members
 * themselves. Leaving the zeroes out made it an average per NODE
 * instead: measured on a channel of albums it came out at 684px
 * against a real 330, and the gap stood twice as tall as what it
 * stood for.
 */
function noteHeight(id, h) {
  const had = heights.get(id);
  if (had !== undefined) {
    hSum -= had;
    hCount -= 1;
  }
  heights.set(id, h);
  hSum += h;
  hCount += 1;
}

/**
 * A gap of exactly this many pixels, written in decimal: one child per
 * non-zero digit, each wearing the class for its place value. Six
 * places, so up to 999999px - longer than any chat gets. Spelled out
 * this way because JS may not write `style`.
 */
function gapNode(px) {
  const box = el('div', { class: 'history__gap' });
  let left = Math.max(0, Math.round(px));
  for (const place of [100000, 10000, 1000, 100, 10, 1]) {
    const d = Math.floor(left / place);
    if (d === 0) continue;
    box.append(el('div', { class: 'gap-' + (d * place) }));
    left -= d * place;
  }
  return box;
}

/**
 * Which message the reader is on. A binary search over the built range
 * rather than a walk: this runs on every scroll event, and reading a
 * node's position forces layout.
 */
function anchorIndex() {
  if (winTo <= winFrom) return -1;
  const top = root.scrollTop;
  let lo = winFrom;
  let hi = winTo - 1;
  let best = winFrom;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const node = winNodes[mid];
    if (!node?.isConnected) { lo = mid + 1; continue; }
    if (node.offsetTop - root.offsetTop <= top) { best = mid; lo = mid + 1; }
    else hi = mid - 1;
  }
  return best;
}

/**
 * Back at the newest end after paging a long way back: everything
 * above is no longer being read, and it is still being held and
 * serialised on every change. Once per arrival, not while sitting
 * there - and the server has the final say on whether anything goes.
 */
function askTrim() {
  if ((lastState?.items.length ?? 0) > TRIM_AT) emit('ui:trim-history');
}

/** Moves the window when the reader has walked to its edge. */
function reframe() {
  if (framing || !lastState) return;

  // Where the reader is, recorded whether or not there is a window to
  // move. A short history is built whole and needs no window - but the
  // page that arrives when the reader reaches the top of it can push
  // the history past the window's size, and then this is the only
  // record of where they were. Without it the window had nothing to
  // centre on and went to the newest message, leaving the reader at
  // the top of a chat looking at a gap.
  const a = anchorIndex();
  if (a >= 0) anchorId = lastState.items[a]?.id ?? null;

  const n = lastState.items.length;
  if (n <= WINDOW) return;
  if (a < 0) return;
  const nearTop = winFrom > 0 && a - winFrom < WINDOW_EDGE;
  const nearEnd = winTo < n && winTo - a < WINDOW_EDGE;
  if (!nearTop && !nearEnd) return;
  render(lastState);
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
  const known = nodes.get(key);
  // Same rule as messageNode, one message at a time.
  if (known && known.group?.length === group.length
      && known.group.every((m, i) => m === group[i])) {
    return known.node;
  }

  const node = renderAlbum(group);
  if (known) {
    reanchorMenu(known.node, node);
    known.node.replaceWith(node);
  }
  nodes.set(key, { node, group, ids: group.map((m) => m.id) });
  return node;
}

function messageNode(msg) {
  const known = nodes.get(msg.id);
  // IDENTITY, not a hash. A message that did not change arrives as the
  // very object it was before (see merged() in core/store.js), so the
  // question "did this change" costs a pointer comparison instead of
  // serialising every message in the window on every refresh.
  if (known && known.msg === msg) return known.node;

  // Видео прежнего узла переезжают в новый — см. renderMessageReusing.
  const node = known ? renderMessageReusing(msg, known.node) : renderMessage(msg);
  // A context menu may be anchored to the node about to be thrown
  // away; it has to follow the message rather than be left pointing at
  // a detached element. See reanchorMenu.
  if (known) {
    reanchorMenu(known.node, node);
    known.node.replaceWith(node);
  }
  nodes.set(msg.id, { node, msg, ids: [msg.id] });
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
  updateFloatDate();
}

// Расстояние плавающей даты от верха истории (= от шапки) — то же, что
// top у .history__float-date в blocks/_history.scss.
const FLOAT_DATE_TOP = 16;

/** Плавающая дата над историей — util/floatdate.js. */
function updateFloatDate() {
  updateFloatDateIn(root, column, floatDate, FLOAT_DATE_TOP);
}

/**
 * Puts the owed message in view, if it has arrived. Offsets rather
 * than scrollIntoView: the same arithmetic the unread divider uses,
 * and scrollIntoView needs a live viewport to centre into - there is
 * none while the window is not being drawn.
 */
/**
 * Узел, на котором стоит сообщение: свой — или альбома, куда оно входит.
 * Альбом кэшируется под ключом `album:<id>`, и по id члена альбома
 * своего узла нет вовсе — прокрутка к фото из альбома (сетка медиа в
 * панели) раньше молча ничего не делала.
 */
function entryFor(id) {
  const own = nodes.get(id);
  if (own) return own;
  for (const entry of nodes.values()) {
    if (entry.group && entry.ids.includes(id)) return entry;
  }
  return null;
}

function showWanted() {
  if (wantMessage === null) return;
  const entry = entryFor(wantMessage);
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
  // Asked HERE as well as from the scroll handler, and for the same
  // reason the window is: arriving at the end by our own hand need not
  // produce a scroll event, and then nothing would ever notice that
  // the reader has come back.
  const arrived = !wasAtBottom;
  atBottom = true;
  wasAtBottom = true;
  if (scrollBtn) scrollBtn.hidden = true;
  if (arrived) askTrim();
  // The end of the chat is only BUILT if the window is down here. Sent
  // from the far end of a long history, this used to land the reader
  // in the gap - the right place in the scroller, with nothing in it -
  // until some later scroll event happened to move the window. Asked
  // for now instead; skipped when a render is already choosing the
  // window for itself.
  reframe();
}

function onScroll() {
  noteScrollPosition();
  if (atBottom && !wasAtBottom) askTrim();
  wasAtBottom = atBottom;
  // Before anything that reads positions: the window may have to move,
  // and everything below wants to look at what is actually built.
  reframe();

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
