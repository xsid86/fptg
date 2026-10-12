import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { CallSession } from '../calls/session.js';
import { routeAudio, devicePanel, togglePanel } from '../calls/devices.js';
import { store } from '../core/store.js';

// Окно звонка: входящий (принять / с видео / отклонить), исходящий
// («Calling…», отмена), идущий (время, эмодзи ключа, микрофон, камера,
// положить трубку) и видео собеседника с превью своей камеры.
//
// Сервер шлёт каждое изменение звонка событием call и каждый сигнальный
// пакет — call.signal (webapi.pas, CallToJson). Медиа ведёт ТА страница,
// которая звонок начала или приняла (owned): у остальных открытых
// страниц входящий звонок звенит, но разговор идёт в одной.
//
// Звонок, завершённый на этой странице, показывает итог ENDED_SHOW_MS
// и закрывается.

const ENDED_SHOW_MS = 2500;
const TICK_MS = 1000;
// Звонок/гудок — синтезом, без файлов: тон и ритм как у телефона.
const RING_TONE_HZ = [440, 480];
const RING_ON_MS = 1000;
const RING_OFF_MS = 2000;

let hooks = {};
let root = null;
let current = null;    // последний объект звонка от сервера
let session = null;    // CallSession, если медиа ведёт эта страница
const owned = new Set();      // id звонков, начатых/принятых здесь
const wantVideo = new Map();  // id -> включить камеру при соединении
let connectedAt = 0;
let tickTimer = 0;
let endTimer = 0;
let remoteMedia = { muted: false, video: false };

// ------------------------------------------------------------ звук
let ringCtx = null;
let ringTimer = 0;

function ringStop() {
  clearTimeout(ringTimer);
  ringTimer = 0;
  if (ringCtx) {
    ringCtx.close().catch(() => {});
    ringCtx = null;
  }
}

function ringStart() {
  if (ringCtx) return;
  try {
    ringCtx = new AudioContext();
  } catch {
    return;
  }
  const burst = () => {
    if (!ringCtx) return;
    const gain = ringCtx.createGain();
    gain.gain.value = 0.08;
    gain.connect(ringCtx.destination);
    const stopAt = ringCtx.currentTime + RING_ON_MS / 1000;
    for (const hz of RING_TONE_HZ) {
      const osc = ringCtx.createOscillator();
      osc.frequency.value = hz;
      osc.connect(gain);
      osc.start();
      osc.stop(stopAt);
    }
    ringTimer = setTimeout(burst, RING_ON_MS + RING_OFF_MS);
  };
  burst();
}

// ------------------------------------------------------------ вид
const REASONS = {
  missed: 'Missed call',
  declined: 'Call declined',
  disconnected: 'Disconnected',
  hungup: 'Call ended',
  empty: 'Call ended',
};

function duration(sec) {
  const m = Math.floor(sec / 60);
  const s = String(sec % 60).padStart(2, '0');
  return m >= 60 ? `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}:${s}` : `${m}:${s}`;
}

function statusText(c) {
  switch (c.state) {
    case 'pending':
      if (!c.outgoing) return c.video ? 'Incoming video call' : 'Incoming call';
      return c.received ? 'Ringing...' : 'Calling...';
    case 'exchangingKeys':
      return 'Exchanging encryption keys...';
    case 'ready':
      return connectedAt ? duration(Math.floor((Date.now() - connectedAt) / 1000)) : 'Connecting...';
    case 'hangingUp':
      return 'Hanging up...';
    case 'discarded':
      return REASONS[c.reason] ?? 'Call ended';
    case 'error':
      return `Call failed: ${c.error || 'unknown error'}`;
    default:
      return c.state;
  }
}

// name — имя иконки спрайта или готовый узел (у «во весь экран» своей
// иконки в спрайте нет — знак ⛶ в кружке той же формы).
const btn = (cls, name, label, onclick) => el('button', {
  class: `call__btn ${cls}`, type: 'button', title: label, onclick,
}, typeof name === 'string' ? icon(name) : name,
el('span', { class: 'call__btn-label', textContent: label }));

// ------------------------------------------------------ во весь экран
// Полноэкранный режим элемента (.call целиком): хост WebView2 на это
// разворачивает окно (webui.pas, ViewFullScreenElement). Выход — та же
// кнопка, Escape или двойной клик по видео.
const isFull = () => document.fullscreenElement === root;

async function toggleFull() {
  try {
    if (isFull()) await document.exitFullscreen();
    else await root.requestFullscreen();
  } catch (error) {
    report(error);
  }
}

// Элементы окна строятся один раз; render() меняет текст, классы и
// видимость. <video> пересоздавать нельзя — потеряется поток.
let ui = null;

function build() {
  const avatar = el('span', { class: 'avatar call__avatar' });
  const name = el('div', { class: 'call__name' });
  const status = el('div', { class: 'call__status u-tabular' });
  const emojis = el('div', { class: 'call__emojis', title: 'If these emoji match on both sides, the call is end-to-end encrypted' });
  // Видео заглушено: звук собеседника — только у <audio> (его выход
  // переключается на выбранный динамик, calls/devices.js).
  const remoteVideo = el('video', { class: 'call__remote', autoplay: true, playsInline: true, muted: true });
  const localVideo = el('video', { class: 'call__local', autoplay: true, playsInline: true, muted: true });
  const remoteAudio = el('audio', { class: 'call__audio', autoplay: true });
  const remoteMuted = el('div', { class: 'call__remote-muted', textContent: 'Microphone is off' });

  const accept = btn('call__btn--accept', 'mic', 'Accept', () => acceptCall(false));
  const acceptVideo = btn('call__btn--accept', 'video', 'Video', () => acceptCall(true));
  const decline = btn('call__btn--hangup', 'close', 'Decline', () => hangUp());
  const mute = btn('call__btn--toggle', 'mic', 'Mute', () => toggleMute());
  const camera = btn('call__btn--toggle', 'video', 'Camera', () => toggleCamera());
  const hangup = btn('call__btn--hangup', 'close', 'End', () => hangUp());
  // Устройства и громкость — панелью в окне (calls/devices.js), не
  // всплывающим меню: меню, открытое от кнопки звонка, после конца
  // звонка оставалось висеть без якоря в углу экрана.
  const levels = devicePanel({ hidden: true });
  const devices = btn('call__btn--toggle', 'settings', 'Devices', () => {
    togglePanel(levels);
    devices.classList.toggle('is-on', !levels.hidden);
  });
  const full = btn('call__btn--toggle', el('span', { class: 'icon call__glyph', textContent: '\u26f6' }),
    'Full screen', () => toggleFull());
  remoteVideo.addEventListener('dblclick', () => toggleFull());
  localVideo.addEventListener('dblclick', () => toggleFull());

  const media = el('div', { class: 'call__media' }, remoteVideo, localVideo);
  const head = el('div', { class: 'call__head' }, avatar, el('div', { class: 'call__who' }, name, status), emojis);
  const actions = el('div', { class: 'call__actions' }, accept, acceptVideo, decline, mute, camera, devices, full, hangup);

  root.append(el('div', { class: 'call__card' }, media, head, remoteMuted, levels, actions, remoteAudio));
  ui = {
    avatar, name, status, emojis, remoteVideo, localVideo, remoteAudio, remoteMuted,
    accept, acceptVideo, decline, mute, camera, hangup, full, devices, levels, media,
  };
}

function render() {
  const c = current;
  root.hidden = !c;
  if (!c) return;
  if (!ui) build();
  fillAvatar(ui.avatar, { id: c.userId, title: c.name, avatar: c.senderAvatar, avatarThumb: c.senderThumb });
  ui.name.textContent = c.name || `User ${c.userId}`;
  ui.status.textContent = statusText(c);
  ui.emojis.textContent = c.state === 'ready' ? (c.emojis ?? []).join(' ') : '';

  const incoming = c.state === 'pending' && !c.outgoing && !owned.has(c.id);
  const finished = c.state === 'discarded' || c.state === 'error';
  const live = !incoming && !finished && owned.has(c.id);
  ui.accept.hidden = !incoming;
  ui.acceptVideo.hidden = !incoming || !c.video;
  ui.decline.hidden = !incoming;
  ui.mute.hidden = !live || c.state !== 'ready';
  ui.camera.hidden = !live || c.state !== 'ready';
  ui.hangup.hidden = !live;
  ui.full.hidden = !live;
  ui.devices.hidden = !live;
  ui.full.classList.toggle('is-on', isFull());
  ui.mute.classList.toggle('is-off', !!session?.muted);
  ui.camera.classList.toggle('is-on', !!session?.videoOn);

  const showVideo = !!session && (remoteMedia.video || session.videoOn);
  root.classList.toggle('call--video', showVideo);
  ui.remoteVideo.hidden = !remoteMedia.video;
  ui.localVideo.hidden = !session?.videoOn;
  ui.remoteMuted.hidden = !(session && remoteMedia.muted);
  root.classList.toggle('call--incoming', incoming);
  root.classList.toggle('call--ended', finished);
}

// ------------------------------------------------------------ действия
function report(error) {
  hooks.report?.(error);
}

async function startCall(userId, video) {
  if (current && current.state !== 'discarded' && current.state !== 'error') {
    hooks.notice?.('Another call is in progress');
    return;
  }
  try {
    const r = await hooks.call('call.start', { userId: String(userId), video: !!video });
    owned.add(r.id);
    wantVideo.set(r.id, !!video);
    // Событие call могло прийти раньше ответа — тогда звонок уже наш.
    if (current?.id === r.id) onCall(current);
  } catch (error) {
    report(error);
  }
}

async function acceptCall(video) {
  const c = current;
  if (!c) return;
  owned.add(c.id);
  wantVideo.set(c.id, video);
  ringStop();
  syncPopup();
  render();
  try {
    await hooks.call('call.accept', { id: c.id });
  } catch (error) {
    owned.delete(c.id);
    report(error);
    render();
  }
}

async function hangUp() {
  const c = current;
  if (!c) return;
  ringStop();
  const secs = connectedAt ? Math.floor((Date.now() - connectedAt) / 1000) : 0;
  try {
    await hooks.call('call.discard', {
      id: c.id, duration: secs, video: !!(session?.videoOn || c.video), connectionId: 0,
      disconnected: false,
    });
  } catch (error) {
    report(error);
  }
}

function toggleMute() {
  if (!session) return;
  session.setMuted(!session.muted);
  render();
}

async function toggleCamera() {
  if (!session) return;
  try {
    await session.setVideo(!session.videoOn);
  } catch (error) {
    report(error);
  }
  render();
}

// ------------------------------------------------------------ сессия
function startSession(c) {
  if (session || !owned.has(c.id)) return;
  if (c.version && c.version !== '10.0.0') {
    // Сервер выбрал версию, которой у страницы нет: собеседник не
    // поддерживает 10.0.0. Честно завершить, а не висеть «Connecting».
    hooks.notice?.(`Call protocol ${c.version} is not supported`);
    hangUp();
    return;
  }
  remoteMedia = { muted: false, video: false };
  session = new CallSession(c, {
    send: (data) => hooks.call('call.signal', { id: c.id, data }).catch(report),
    on: {
      state: (s) => {
        if (s === 'connected' && !connectedAt) {
          connectedAt = Date.now();
          clearInterval(tickTimer);
          tickTimer = setInterval(render, TICK_MS);
        }
        if (s === 'failed') hooks.notice?.('Call connection failed');
        render();
      },
      remoteStream: (stream) => {
        ui.remoteAudio.srcObject = stream;
        ui.remoteVideo.srcObject = stream;
        routeAudio(ui.remoteAudio);
      },
      localStream: (stream) => {
        ui.localVideo.srcObject = stream;
        render();
      },
      remoteMedia: (m) => {
        remoteMedia = m;
        render();
      },
      log: (...m) => console.debug('[call]', ...m),
    },
  });
  session.start(wantVideo.get(c.id) ?? false).catch((error) => {
    report(error);
    hangUp();
  });
}

function endSession() {
  if (isFull()) document.exitFullscreen().catch(() => {});
  session?.close();
  session = null;
  connectedAt = 0;
  clearInterval(tickTimer);
  tickTimer = 0;
  if (ui) {
    ui.remoteAudio.srcObject = null;
    ui.remoteVideo.srcObject = null;
    ui.localVideo.srcObject = null;
  }
}

// ------------------------------------------------ окошко поверх всех
// Входящий звонит, а окно не на виду (свёрнуто, в трее, позади других) —
// просим оболочку показать карточку поверх всех окон (callpopup.pas;
// на другой платформе — её окно). Решает страница, оболочка только
// показывает. Карточке — всё в адресе (callcard.html), сервер она не
// спрашивает; нажатия возвращаются сюда сообщением оболочки.
const host = () => window.chrome?.webview ?? null;
let popupFor = 0;     // id звонка, чья карточка показана

const ringingHere = (c) => !!c && c.state === 'pending' && !c.outgoing && !owned.has(c.id);
const pageOutOfSight = () => document.hidden || !document.hasFocus();

function popupUrl(c) {
  const q = new URLSearchParams({
    id: String(c.id),
    name: c.name || '',
    video: c.video ? '1' : '0',
    uid: String(c.userId ?? ''),
    avatar: c.senderAvatar || '',
    thumb: c.senderThumb || '',
  });
  return `${location.origin}/callcard.html?${q}`;
}

function syncPopup() {
  const h = host();
  if (!h) return;
  const want = ringingHere(current) && pageOutOfSight() ? current.id : 0;
  if (want === popupFor) return;
  popupFor = want;
  h.postMessage(JSON.stringify(want
    ? { t: 'callpopup', show: true, url: popupUrl(current) }
    : { t: 'callpopup', show: false }));
}

// Нажатие на карточке (оболочка передала его сюда).
function onHostMessage(m) {
  if (m?.t !== 'call') return;
  popupFor = 0;
  if (!current || current.id !== m.id) return;
  if (m.action === 'accept') acceptCall(!!current.video);
  else if (m.action === 'decline') hangUp();
  // open — оболочка уже подняла окно, звонок звонит в окне
}

function onCall(c) {
  // Чужой звонок поверх идущего своего — не перехватывать окно (второй
  // входящий TDLib сам отклонит как «занято», если мы в разговоре).
  if (current && c.id !== current.id && session) return;
  clearTimeout(endTimer);
  current = c;
  const finished = c.state === 'discarded' || c.state === 'error' || c.state === 'hangingUp';
  if (c.state === 'pending' && !c.outgoing && !owned.has(c.id)) ringStart();
  else ringStop();
  if (c.state === 'ready') startSession(c);
  if (finished) {
    endSession();
    if (c.state !== 'hangingUp') {
      owned.delete(c.id);
      wantVideo.delete(c.id);
      endTimer = setTimeout(() => {
        if (current?.id === c.id) current = null;
        render();
      }, ENDED_SHOW_MS);
    }
  }
  syncPopup();
  render();
}

export function mountCalls(options) {
  hooks = options ?? {};
  root = el('div', { class: 'call', hidden: true, role: 'dialog', 'aria-label': 'Call' });
  document.body.append(root);
  document.addEventListener('fullscreenchange', () => render());
  // Окно вернулось на экран — карточка поверх всех больше не нужна, и
  // наоборот: ушло, пока звонит, — показать.
  window.addEventListener('focus', syncPopup);
  window.addEventListener('blur', syncPopup);
  document.addEventListener('visibilitychange', syncPopup);
  host()?.addEventListener('message', (event) => onHostMessage(event.data));

  on('srv:call', (c) => { if (c) onCall(c); });
  on('srv:call.signal', ({ id, data } = {}) => {
    if (session && session.call.id === id) session.receive(data);
  });
  on('ui:call-start', ({ userId, video } = {}) => startCall(userId, video));
  // Выбрали другое устройство — в идущем звонке сразу на него.
  on('calls:device', ({ kind } = {}) => {
    if (kind === 'speaker' && ui) routeAudio(ui.remoteAudio);
    if (!session) return;
    const run = kind === 'mic' ? session.switchMic() : (kind === 'camera' ? session.switchCamera() : null);
    run?.catch(report);
  });
  // «Перезвонить» из звонка в истории: собеседник — открытый личный чат
  // (id лички = id пользователя).
  on('ui:call-back', ({ video } = {}) => {
    if (store.activeChatId > 0) startCall(store.activeChatId, video);
  });
  // Страница открылась посреди звонка: входящий ещё звенит.
  hooks.call('call.list')
    .then((r) => {
      for (const c of r?.calls ?? []) onCall(c);
    })
    .catch(() => {});
}
