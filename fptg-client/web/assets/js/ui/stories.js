import { el, clear } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { listTime } from '../util/format.js';

// Viewing a chat's stories (a click on the ring in the list, ui/chat-list.js
// -> ui:stories-open). The server: story.list / story.open / story.close
// (webapi.pas). story.open also calls openStory — TDLib counts the story as
// viewed, and the ring in the list turns grey by itself
// (updateChatActiveStories).
//
// The look as in the official clients: a 9:16 card in the centre of the
// dimming, bars at the top, one per story (<progress>: value is a property,
// not style), a header with the avatar and time, a photo or video, a caption.
// A photo — PHOTO_MS, a video — to the end. After the last one — close.
// The start — from the first unread one (id > max_read_story_id).

const PHOTO_MS = 5000;
const TICK_MS = 50;
const PROGRESS_MAX = 1000;

let hooks = {};
let root = null;
let ui = null;
let state = null;   // { chat, list, index, gen, timer, started, elapsed, paused, total }

const call = (cmd, args) => hooks.call(cmd, args);

function build() {
  const bars = el('div', { class: 'stories__bars' });
  const avatar = el('span', { class: 'avatar avatar--sm stories__avatar' });
  const name = el('span', { class: 'stories__name' });
  const time = el('span', { class: 'stories__time' });
  const media = el('div', { class: 'stories__media' });
  const caption = el('div', { class: 'stories__caption' });
  const close = el('button', {
    class: 'btn btn--icon stories__close', type: 'button', title: 'Close',
    onclick: () => closeViewer(),
  }, icon('close'));
  const prev = el('button', {
    class: 'stories__nav stories__nav--prev', type: 'button', title: 'Previous',
    onclick: () => step(-1),
  });
  const next = el('button', {
    class: 'stories__nav stories__nav--next', type: 'button', title: 'Next',
    onclick: () => step(1),
  });
  const card = el('div', { class: 'stories__card' },
    media, prev, next,
    el('div', { class: 'stories__top' }, bars,
      el('div', { class: 'stories__head' }, avatar,
        el('span', { class: 'stories__who' }, name, time), close)),
    caption);
  root.append(card);
  // A click on the dimming around the card — close.
  root.addEventListener('click', (e) => { if (e.target === root) closeViewer(); });
  ui = { bars, avatar, name, time, media, caption, card };
}

function paintBars() {
  clear(ui.bars).append(...state.list.map((s, i) => {
    const p = el('progress', { class: 'stories__bar', max: PROGRESS_MAX });
    p.value = i < state.index ? PROGRESS_MAX : 0;
    return p;
  }));
}

function setProgress(fraction) {
  const bar = ui.bars.children[state.index];
  if (bar) bar.value = Math.round(Math.min(1, Math.max(0, fraction)) * PROGRESS_MAX);
}

function stopClock() {
  clearInterval(state?.timer);
  if (state) state.timer = 0;
}

/** The photo clock: PHOTO_MS accounting for pauses. */
function startPhotoClock() {
  stopClock();
  state.started = Date.now() - state.elapsed;
  state.timer = setInterval(() => {
    if (state.paused) return;
    state.elapsed = Date.now() - state.started;
    setProgress(state.elapsed / PHOTO_MS);
    if (state.elapsed >= PHOTO_MS) step(1);
  }, TICK_MS);
}

function leaveCurrent() {
  const s = state?.list[state.index];
  if (s) call('story.close', { chatId: state.chat.id, storyId: s.id }).catch(() => {});
  stopClock();
  const v = ui?.media.querySelector('video');
  if (v) {
    v.pause();
    v.removeAttribute('src');
    v.load();
  }
}

async function show(index) {
  leaveCurrent();
  state.index = index;
  state.elapsed = 0;
  state.paused = false;
  paintBars();
  const gen = Symbol('story');
  state.gen = gen;
  const s = state.list[index];
  ui.time.textContent = listTime(s.date);
  ui.caption.textContent = '';
  ui.caption.hidden = true;
  clear(ui.media).append(el('div', { class: 'stories__wait' }, el('span', { class: 'spinner' })));
  let info;
  try {
    info = await call('story.open', { chatId: state.chat.id, storyId: s.id });
  } catch (e) {
    if (state?.gen !== gen) return;
    hooks.report?.(e);
    clear(ui.media).append(el('div', { class: 'stories__note' }, 'This story is unavailable'));
    startPhotoClock();
    return;
  }
  if (state?.gen !== gen) return;
  ui.caption.textContent = info.caption || '';
  ui.caption.hidden = !info.caption;
  if (info.thumb) clear(ui.media).append(el('img', { class: 'stories__thumb', src: info.thumb, alt: '' }));
  if (!info.url || info.kind === 'unsupported') {
    clear(ui.media).append(el('div', { class: 'stories__note' },
      info.kind === 'unsupported' ? 'This story cannot be shown here yet' : 'The story could not be loaded'));
    startPhotoClock();
    return;
  }
  if (info.kind === 'photo') {
    const img = el('img', { class: 'stories__img', src: info.url, alt: '' });
    img.addEventListener('load', () => { if (state?.gen === gen) startPhotoClock(); }, { once: true });
    img.addEventListener('error', () => { if (state?.gen === gen) startPhotoClock(); }, { once: true });
    ui.media.append(img);
    return;
  }
  const video = el('video', { class: 'stories__video', src: info.url, autoplay: true, playsInline: true });
  video.addEventListener('timeupdate', () => {
    if (state?.gen === gen && video.duration) setProgress(video.currentTime / video.duration);
  });
  video.addEventListener('ended', () => { if (state?.gen === gen) step(1); });
  video.addEventListener('error', () => { if (state?.gen === gen) startPhotoClock(); });
  ui.media.append(video);
  // The browser allows sound only after a user gesture; if it did not —
  // at least without sound rather than a still frame.
  video.play().catch(() => {
    if (state?.gen !== gen) return;
    video.muted = true;
    video.play().catch(() => {});
  });
}

function step(delta) {
  if (!state) return;
  const to = state.index + delta;
  if (to < 0) {
    show(0);
    return;
  }
  if (to >= state.list.length) {
    closeViewer();
    return;
  }
  show(to);
}

function togglePause() {
  if (!state) return;
  state.paused = !state.paused;
  const v = ui.media.querySelector('video');
  if (v) {
    if (state.paused) v.pause();
    else v.play().catch(() => {});
  } else if (!state.paused && state.timer) {
    state.started = Date.now() - state.elapsed;
  }
  ui.card.classList.toggle('is-paused', state.paused);
}

function onKey(e) {
  if (!state) return;
  if (e.key === 'Escape') closeViewer();
  else if (e.key === 'ArrowRight') step(1);
  else if (e.key === 'ArrowLeft') step(-1);
  else if (e.key === ' ') togglePause();
  else return;
  e.preventDefault();
  e.stopPropagation();
}

function closeViewer() {
  if (!state) return;
  leaveCurrent();
  state = null;
  root.hidden = true;
  document.removeEventListener('keydown', onKey, true);
}

/** chat — a list row (id, title, avatar, avatarThumb, color). */
export async function openStories(chat) {
  if (!chat) return;
  if (state) closeViewer();
  let r;
  try {
    r = await call('story.list', { chatId: chat.id });
  } catch (e) {
    hooks.report?.(e);
    return;
  }
  const list = r?.stories ?? [];
  if (!list.length) {
    hooks.notice?.('No active stories');
    return;
  }
  if (!ui) build();
  state = { chat, list, index: 0, timer: 0, elapsed: 0, paused: false, gen: null };
  ui.name.textContent = chat.title || 'Stories';
  ui.avatar.className = `avatar avatar--sm stories__avatar accent-${chat.color || 'a5'}`;
  fillAvatar(ui.avatar, chat);
  root.hidden = false;
  document.addEventListener('keydown', onKey, true);
  const firstUnread = list.findIndex((s) => s.id > (r.maxRead ?? 0));
  show(firstUnread >= 0 ? firstUnread : 0);
}

export function mountStories(options) {
  hooks = options ?? {};
  root = el('div', { class: 'stories', hidden: true, role: 'dialog', 'aria-label': 'Stories' });
  document.body.append(root);
  on('ui:stories-open', (chat) => { openStories(chat).catch(hooks.report); });
}
