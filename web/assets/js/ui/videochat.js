import { el, clear } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { formDialog } from './bots.js';
import { GroupSession } from '../calls/group.js';
import { routeAudio, devicePanel, togglePanel } from '../calls/devices.js';
import { store } from '../core/store.js';

// Окно видеочата (группового звонка чата): плитки участников (видео или
// аватарка, имя, микрофон, рамка у говорящего), кнопки — микрофон,
// камера, во весь экран, выйти, завершить для всех (если можно).
//
// Сервер: vchat.* и события vchat, vchat.participant (webapi.pas);
// медиа — calls/group.js. Входят с выключенным микрофоном, как в
// официальных клиентах.

const SPEAK_LEVEL = 0.02;     // порог «говорит» по уровню звука (0..1)
const SPEAK_TICK_MS = 200;
const SPEAK_HOLD_MS = 600;    // не мигать рамкой между словами

let hooks = {};
let root = null;
let ui = null;
let state = null;   // { chatId, title, callId, call, parts: Map, session, muted, video }
let speakTimer = 0;
let audioCtx = null;
const meters = new Map();     // key -> { analyser, buf, last }
const videos = new Map();     // key (с #screen для экрана) -> MediaStream

function report(error) {
  hooks.report?.(error);
}

// ------------------------------------------------------------ звук
function meter(key, stream) {
  try {
    audioCtx ??= new AudioContext();
    const src = audioCtx.createMediaStreamSource(stream);
    const analyser = audioCtx.createAnalyser();
    analyser.fftSize = 512;
    src.connect(analyser);
    meters.set(key, { analyser, buf: new Float32Array(analyser.fftSize), last: 0 });
  } catch {
    // без измерителя — только флаг is_speaking от сервера
  }
}

function levelOf(m) {
  m.analyser.getFloatTimeDomainData(m.buf);
  let sum = 0;
  for (const v of m.buf) sum += v * v;
  return Math.sqrt(sum / m.buf.length);
}

function speakingTick() {
  const now = Date.now();
  for (const m of meters.values()) {
    if (levelOf(m) > SPEAK_LEVEL) m.last = now;
  }
  for (const tile of ui?.grid.children ?? []) {
    const m = meters.get(tile.dataset.key);
    const p = state?.parts.get(tile.dataset.key);
    tile.classList.toggle('is-speaking', !!(m && now - m.last < SPEAK_HOLD_MS) || !!p?.speaking);
  }
}

// ------------------------------------------------------------ вид
const btn = (cls, iconNode, label, onclick) => el('button', {
  class: `call__btn ${cls}`, type: 'button', title: label, onclick,
}, iconNode, el('span', { class: 'call__btn-label', textContent: label }));

function build() {
  const title = el('div', { class: 'vchat__title' });
  const count = el('div', { class: 'vchat__count u-dim' });
  const status = el('div', { class: 'vchat__status' });
  const grid = el('div', { class: 'vchat__grid' });
  const audio = el('div', { class: 'vchat__audio' });
  const mic = btn('call__btn--toggle', icon('mic'), 'Unmute', () => toggleMic());
  const camera = btn('call__btn--toggle', icon('video'), 'Camera', () => toggleCamera());
  const full = btn('call__btn--toggle', el('span', { class: 'icon call__glyph', textContent: '⛶' }),
    'Full screen', () => toggleFull());
  const levels = devicePanel({ hidden: true });
  const devices = btn('call__btn--toggle', icon('settings'), 'Devices', () => {
    togglePanel(levels);
    devices.classList.toggle('is-on', !levels.hidden);
  });
  const leave = btn('call__btn--hangup', icon('close'), 'Leave', () => leaveChat());
  const end = btn('call__btn--hangup', icon('close'), 'End for all', () => endChat());
  root.append(el('div', { class: 'vchat__card' },
    el('div', { class: 'vchat__head' }, el('div', { class: 'vchat__who' }, title, count), status),
    grid,
    levels,
    el('div', { class: 'call__actions' }, mic, camera, devices, full, leave, end),
    audio));
  ui = { title, count, status, grid, audio, mic, camera, full, leave, end };
}

function tileFor(p) {
  const avatar = el('span', { class: 'avatar vchat__avatar' });
  fillAvatar(avatar, { id: p.id, title: p.name, avatar: p.senderAvatar, avatarThumb: p.senderThumb });
  const muted = p.mutedAll || p.mutedMe || (p.self && state.muted);
  return el('div', {
    class: `vchat__tile${muted ? ' is-muted' : ''}${p.self ? ' is-self' : ''}`,
    dataset: { key: p.key },
  }, avatar,
  el('div', { class: 'vchat__name' },
    icon('mic', `icon--sm vchat__mic${muted ? ' is-off' : ''}`),
    el('span', { textContent: p.self ? `${p.name || 'You'} (you)` : (p.name || 'Participant') }),
    p.handRaised ? el('span', { class: 'vchat__hand', textContent: '✋' }) : null));
}

function videoNode(stream, mirrored) {
  const v = el('video', { class: `vchat__video${mirrored ? ' is-mirrored' : ''}`, autoplay: true, playsInline: true, muted: true });
  v.srcObject = stream;
  return v;
}

const isFull = () => document.fullscreenElement === root;

function render() {
  root.hidden = !state;
  if (!state) return;
  if (!ui) build();
  ui.title.textContent = state.title || 'Video chat';
  const n = state.call?.count ?? state.parts.size;
  ui.count.textContent = `${n} participant${n === 1 ? '' : 's'}`;
  ui.status.textContent = state.status ?? '';
  const list = [...state.parts.values()]
    .filter((p) => p.order)
    .sort((a, b) => (b.self - a.self) || (a.order < b.order ? 1 : a.order > b.order ? -1 : 0));
  const tiles = [];
  for (const p of list) {
    const tile = tileFor(p);
    const own = p.self && state.video && state.session?.cam;
    const stream = own ? state.session.cam : videos.get(p.key);
    if (stream) tile.prepend(videoNode(stream, own));
    tiles.push(tile);
    const screen = videos.get(`${p.key}#screen`);
    if (screen) {
      const st = el('div', { class: 'vchat__tile vchat__tile--screen', dataset: { key: `${p.key}#screen` } },
        el('div', { class: 'vchat__name' }, el('span', { textContent: `${p.name} (screen)` })));
      st.prepend(videoNode(screen, false));
      tiles.push(st);
    }
  }
  clear(ui.grid).append(...tiles);
  root.classList.toggle('vchat--many', tiles.length > 4);
  const self = list.find((p) => p.self);
  const forced = self && self.mutedAll && !self.canUnmuteSelf;
  ui.mic.classList.toggle('is-off', state.muted);
  ui.mic.querySelector('.call__btn-label').textContent = state.muted ? 'Unmute' : 'Mute';
  ui.mic.disabled = !!forced;
  ui.camera.classList.toggle('is-on', !!state.video);
  ui.camera.hidden = state.call && !state.call.canEnableVideo;
  ui.full.classList.toggle('is-on', isFull());
  ui.end.hidden = !state.call?.canManage;
}

// ------------------------------------------------------------ действия
async function toggleFull() {
  try {
    if (isFull()) await document.exitFullscreen();
    else await root.requestFullscreen();
  } catch (error) {
    report(error);
  }
}

function selfKey() {
  return [...state.parts.values()].find((p) => p.self)?.key;
}

async function toggleMic() {
  if (!state?.session) return;
  const muted = !state.muted;
  state.muted = muted;
  state.session.setMuted(muted);
  render();
  const key = selfKey();
  if (key) {
    hooks.call('vchat.mute', { groupCallId: state.callId, key, muted }).catch(report);
  }
}

async function toggleCamera() {
  if (!state?.session) return;
  const want = !state.video;
  try {
    await state.session.setVideo(want);
    state.video = want;
    await hooks.call('vchat.video', { groupCallId: state.callId, enabled: want });
  } catch (error) {
    report(error);
  }
  render();
}

function teardown() {
  if (isFull()) document.exitFullscreen().catch(() => {});
  state?.session?.close();
  clearInterval(speakTimer);
  speakTimer = 0;
  meters.clear();
  videos.clear();
  if (ui) clear(ui.audio);
  state = null;
  render();
}

async function leaveChat() {
  if (!state) return;
  const id = state.callId;
  teardown();
  try {
    await hooks.call('vchat.leave', { groupCallId: id });
  } catch (error) {
    report(error);
  }
}

async function endChat() {
  if (!state) return;
  if (!(await formDialog({ text: 'End the video chat for everyone?', ok: 'End' }))) return;
  const id = state.callId;
  teardown();
  try {
    await hooks.call('vchat.end', { groupCallId: id });
  } catch (error) {
    report(error);
  }
}

function applyParticipant(p) {
  if (!p.order) {
    state.parts.delete(p.key);
    videos.delete(p.key);
    videos.delete(`${p.key}#screen`);
    meters.delete(p.key);
  } else {
    state.parts.set(p.key, p);
    // Сервер выключил микрофон (админ) — наша дорожка тоже молчит.
    if (p.self && p.mutedAll && !state.muted) {
      state.muted = true;
      state.session?.setMuted(true);
    }
  }
}

function pushParticipants() {
  state?.session?.setParticipants([...state.parts.values()].map((p) => ({ ...p, left: !p.order })));
}

/** Открыть видеочат чата: войти в идущий или начать новый. */
async function openChat({ chatId, title }) {
  if (state) {
    if (state.chatId === chatId) return;
    hooks.notice?.('Leave the current video chat first');
    return;
  }
  let info;
  try {
    info = await hooks.call('vchat.info', { chatId });
  } catch (error) {
    report(error);
    return;
  }
  let callId = info.groupCallId;
  if (!callId || !info.call?.active) {
    if (!(await formDialog({ text: 'Start a video chat in this chat?', ok: 'Start' }))) return;
    try {
      callId = (await hooks.call('vchat.create', { chatId })).groupCallId;
    } catch (error) {
      report(error);
      return;
    }
  }
  if (info.call?.rtmp) {
    hooks.notice?.('Live streams are not supported yet');
    return;
  }
  state = {
    chatId, title, callId, call: info.call, parts: new Map(), muted: true, video: false,
    status: 'Joining...',
  };
  render();
  const session = new GroupSession({
    join: async (args) => (await hooks.call('vchat.join', { groupCallId: callId, ...args })).payload,
    on: {
      track: ({ key, kind, stream }) => {
        if (!state) return;
        if (kind === 'audio') {
          const a = el('audio', { autoplay: true });
          a.srcObject = stream;
          ui.audio.append(a);
          routeAudio(a);
          meter(key.replace('#screen', ''), stream);
        } else {
          videos.set(key, stream);
          render();
        }
      },
      untrack: ({ key, kind }) => {
        if (kind === 'video') {
          videos.delete(key);
          render();
        }
      },
      state: (s) => {
        if (!state) return;
        state.status = s === 'connected' ? '' : (s === 'failed' ? 'Connection failed' : 'Connecting...');
        render();
      },
      log: (...m) => console.debug('[vchat]', ...m),
    },
  });
  state.session = session;
  try {
    await session.start({ muted: true, video: false });
    if (!state) return;
    state.status = 'Connecting...';
    const r = await hooks.call('vchat.participants', { groupCallId: callId });
    for (const p of r?.participants ?? []) applyParticipant(p);
    pushParticipants();
    clearInterval(speakTimer);
    speakTimer = setInterval(speakingTick, SPEAK_TICK_MS);
    render();
  } catch (error) {
    report(error);
    teardown();
  }
}

export function mountVideoChat(options) {
  hooks = options ?? {};
  root = el('div', { class: 'call vchat', hidden: true, role: 'dialog', 'aria-label': 'Video chat' });
  document.body.append(root);
  document.addEventListener('fullscreenchange', () => { if (state) render(); });

  on('ui:vchat-open', (args) => { openChat(args ?? {}); });
  on('calls:device', ({ kind } = {}) => {
    if (kind === 'speaker' && ui) {
      for (const a of ui.audio.querySelectorAll('audio')) routeAudio(a);
    }
    const s = state?.session;
    if (!s) return;
    const run = kind === 'mic' ? s.switchMic() : (kind === 'camera' ? s.switchCamera() : null);
    run?.catch(report);
  });
  // «Join» у идущего группового звонка в истории — видеочат открытого чата.
  on('ui:vchat-join', () => {
    const chat = store.chats.find((c) => c.id === store.activeChatId);
    if (store.activeChatId !== null) openChat({ chatId: store.activeChatId, title: chat?.title });
  });
  on('srv:vchat', (call) => {
    if (!state || !call || call.id !== state.callId) return;
    state.call = call;
    if (!call.active) {
      hooks.notice?.('The video chat has ended');
      teardown();
      return;
    }
    render();
  });
  on('srv:vchat.participant', ({ callId, participant } = {}) => {
    if (!state || callId !== state.callId || !participant) return;
    applyParticipant(participant);
    pushParticipants();
    render();
  });
}
