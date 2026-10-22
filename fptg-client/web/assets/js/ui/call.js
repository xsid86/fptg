import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { CallSession } from '../calls/session.js';
import { routeAudio, devicePanel, togglePanel } from '../calls/devices.js';
import { store } from '../core/store.js';
import { ringFor } from '../util/sounds.js';

// The call window: incoming (accept / with video / decline), outgoing
// ("Calling…", cancel), ongoing (time, key emoji, microphone, camera, hang
// up) and the other side's video with a preview of one's own camera.
//
// The server sends every call change as a call event and every signalling
// packet as call.signal (webapi.pas, CallToJson). The media is run by THE
// page that started or accepted the call (owned): on the other open pages
// an incoming call rings, but the conversation goes on in one.
//
// A call ended on this page shows the outcome for ENDED_SHOW_MS and closes.

const ENDED_SHOW_MS = 2500;
const TICK_MS = 1000;

let hooks = {};
let root = null;
let current = null;    // the latest call object from the server
let session = null;    // a CallSession, if this page runs the media
const owned = new Set();      // ids of calls started/accepted here
const wantVideo = new Map();  // id -> turn the camera on when connected
let connectedAt = 0;
let tickTimer = 0;
let endTimer = 0;
let remoteMedia = { muted: false, video: false };

// ------------------------------------------------------------ sound
// The ringtone itself is util/sounds.js; it rings while an incoming call
// waits here (see ringFor there for the Android app in the background).
const ringStop = () => ringFor(false);

// ------------------------------------------------------------ view
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

// name — a sprite icon name or a ready node ("full screen" has no icon of
// its own in the sprite — the ⛶ sign in a circle of the same shape).
const btn = (cls, name, label, onclick) => el('button', {
  class: `call__btn ${cls}`, type: 'button', title: label, onclick,
}, typeof name === 'string' ? icon(name) : name,
el('span', { class: 'call__btn-label', textContent: label }));

// ------------------------------------------------------ full screen
// Full-screen mode of an element (.call whole): the WebView2 host expands
// the window for it (webui.pas, ViewFullScreenElement). Exit — the same
// button, Escape or a double click on the video.
const isFull = () => document.fullscreenElement === root;

async function toggleFull() {
  try {
    if (isFull()) await document.exitFullscreen();
    else await root.requestFullscreen();
  } catch (error) {
    report(error);
  }
}

// The window's elements are built once; render() changes text, classes and
// visibility. A <video> must not be recreated — the stream would be lost.
let ui = null;

function build() {
  const avatar = el('span', { class: 'avatar call__avatar' });
  const name = el('div', { class: 'call__name' });
  const status = el('div', { class: 'call__status u-tabular' });
  const emojis = el('div', { class: 'call__emojis', title: 'If these emoji match on both sides, the call is end-to-end encrypted' });
  // The video is muted: the other side's sound is only in <audio> (its
  // output switches to the chosen speaker, calls/devices.js).
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
  // Devices and volume — a panel in the window (calls/devices.js), not a
  // pop-up menu: a menu opened from a call button stayed hanging without an
  // anchor in the corner of the screen after the call ended.
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

// ------------------------------------------------------------ actions
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
    // The call event may have come before the answer — then the call is ours already.
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

// ------------------------------------------------------------ session
function startSession(c) {
  if (session || !owned.has(c.id)) return;
  if (c.version && c.version !== '10.0.0') {
    // The server chose a version the page does not have: the other side
    // does not support 10.0.0. End honestly rather than hang at "Connecting".
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

// ------------------------------------------------ a small window on top of all
// An incoming call rings, and the window is not in view (minimized, in the
// tray, behind others) — ask the shell to show a card on top of all windows
// (callpopup.pas; on another platform — its window). The page decides, the
// shell only shows. The card has everything in its address
// (callcard.html), it does not ask the server; presses come back here as a
// shell message.
const host = () => window.chrome?.webview ?? null;
let popupFor = 0;     // the id of the call whose card is shown

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

// A press on the card (the shell passed it here).
function onHostMessage(m) {
  if (m?.t !== 'call') return;
  popupFor = 0;
  if (!current || current.id !== m.id) return;
  if (m.action === 'accept') acceptCall(!!current.video);
  else if (m.action === 'decline') hangUp();
  // open — the shell has raised the window already, the call rings in the window
}

function onCall(c) {
  // Someone else's call over an ongoing own one — do not take over the
  // window (TDLib itself declines a second incoming one as "busy" if we are talking).
  if (current && c.id !== current.id && session) return;
  clearTimeout(endTimer);
  current = c;
  const finished = c.state === 'discarded' || c.state === 'error' || c.state === 'hangingUp';
  ringFor(ringingHere(c));
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
  // The window came back on screen — the card on top of all is no longer
  // needed, and the other way round: it left while ringing — show it.
  window.addEventListener('focus', syncPopup);
  window.addEventListener('blur', syncPopup);
  document.addEventListener('visibilitychange', syncPopup);
  // Back on screen (or gone) in the Android app: the page's ring or the
  // shell's takes over.
  document.addEventListener('visibilitychange', () => ringFor(ringingHere(current)));
  host()?.addEventListener('message', (event) => onHostMessage(event.data));

  on('srv:call', (c) => { if (c) onCall(c); });
  on('srv:call.signal', ({ id, data } = {}) => {
    if (session && session.call.id === id) session.receive(data);
  });
  on('ui:call-start', ({ userId, video } = {}) => startCall(userId, video));
  // Another device chosen — in an ongoing call switch to it at once.
  on('calls:device', ({ kind } = {}) => {
    if (kind === 'speaker' && ui) routeAudio(ui.remoteAudio);
    if (!session) return;
    const run = kind === 'mic' ? session.switchMic() : (kind === 'camera' ? session.switchCamera() : null);
    run?.catch(report);
  });
  // "Call back" from a call in the history: the other side is the open
  // private chat (private chat id = user id).
  on('ui:call-back', ({ video } = {}) => {
    if (store.activeChatId > 0) startCall(store.activeChatId, video);
  });
  // The page opened in the middle of a call: an incoming one is still ringing.
  hooks.call('call.list')
    .then((r) => {
      for (const c of r?.calls ?? []) onCall(c);
    })
    .catch(() => {});
}
