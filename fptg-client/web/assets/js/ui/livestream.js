import { el, clear } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { parseLocal, joinPayload } from '../calls/group.js';

// Окно трансляции — RTMP-эфира канала или группы (groupCall.is_rtmp_stream).
// Медиа идёт не по WebRTC, а секундными кусками через TDLib
// (vchat.streams / vchat.segment, webapi.pas). Порядок — по документации
// Telegram (core.telegram.org/api/group-calls, «RTMP mode») и tgcalls
// (StreamingMediaContext, VideoStreamingPart):
//
//  1. Вход как в видеочат (vchat.join): WebRTC-описание нужно только для
//     join-payload, сам PeerConnection сразу закрывается — ответ сервера
//     {"stream":true,"rtmp":true}.
//  2. Список каналов (getGroupCallStreams): пустой или ошибка — эфир не
//     идёт («… is not streaming right now»), спросить снова позже. У
//     живого — time_offset, конец потока; старт на STREAM_BUFFER_MS
//     раньше, по сетке STREAM_SEGMENT_MS.
//  3. Куски канала 1 (в RTMP — видео и звук вместе), качество full,
//     scale 0 (секунда), один за другим. «Не готов» (FLOOD_WAIT /
//     TIME_TOO_BIG — у TDLib это 429) — тот же кусок через
//     STREAM_RETRY_MS. Слишком долго не готов — назад к шагу 2.
//
// Кусок: заголовок tgcalls (сигнатура 0xa12e810d, имя контейнера,
// маска, одно событие со смещением и поворотом), за ним — сам контейнер
// (по имени: «mp4»). Фрагментированный MP4 идёт в MediaSource подряд;
// обычный — запасной путь: каждый кусок своим <video>, два по очереди.
//
// ПРОВЕРЕНО ЖИВЬЁМ: вход, ответ {"stream":true,"rtmp":true}, пустой эфир
// (FLOOD_WAIT на списке каналов — так же «не ведёт трансляцию» у
// официального клиента). НЕ ПРОВЕРЕНО: разбор и проигрывание кусков — не
// было эфира с картинкой.

const STREAM_SEGMENT_MS = 1000;
const STREAM_BUFFER_MS = 2000;
const STREAM_RETRY_MS = 100;
const STREAM_POLL_MS = 5000;           // эфир не идёт — спросить снова через
const STREAM_STALL_MS = 10000;         // кусок не готов столько — эфир пропал
const PART_SIGNATURE = 0xa12e810d;

let hooks = {};
let root = null;
let ui = null;
let state = null;   // { chatId, title, callId, count, gen, ... }

const call = (cmd, args) => hooks.call(cmd, args);

function report(error) {
  hooks.report?.(error);
}

// ------------------------------------------------------------ кусок
function b64bytes(s) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
  return out;
}

/** Строка tgcalls: длина байтом (254 — дальше 3 байта длины), байты, выравнивание на 4. */
function readString(view, bytes, pos) {
  let len = view.getUint8(pos);
  let head = 1;
  if (len === 254) {
    len = view.getUint8(pos + 1) | (view.getUint8(pos + 2) << 8) | (view.getUint8(pos + 3) << 16);
    head = 4;
  }
  const text = new TextDecoder().decode(bytes.subarray(pos + head, pos + head + len));
  const used = head + len;
  return { text, next: pos + used + ((4 - (used % 4)) % 4) };
}

/** Заголовок куска -> { container, rotation, media } или null. */
export function parsePart(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.length < 8 || view.getUint32(0, true) !== PART_SIGNATURE) return null;
  const container = readString(view, bytes, 4);
  let pos = container.next;
  pos += 4;                                   // activeMask
  pos += 4;                                   // eventCount (tgcalls читает одно событие)
  const offset = view.getInt32(pos, true);
  const endpoint = readString(view, bytes, pos + 4);
  pos = endpoint.next;
  const rotation = view.getInt32(pos, true);
  pos += 8;                                   // rotation + extra
  if (offset < 0 || pos + offset > bytes.length) return null;
  return { container: container.text, rotation, media: bytes.subarray(pos + offset) };
}

// ------------------------------------------------------------ MP4
/** Верхние коробки MP4: [{ type, start, size }]. */
function boxes(bytes, from = 0, to = bytes.length) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = [];
  let pos = from;
  while (pos + 8 <= to) {
    let size = view.getUint32(pos);
    const type = String.fromCharCode(...bytes.subarray(pos + 4, pos + 8));
    if (size === 1) size = Number(view.getBigUint64(pos + 8));
    if (size < 8 || pos + size > to) break;
    out.push({ type, start: pos, size });
    pos += size;
  }
  return out;
}

/** Первая коробка type внутри (поиск по байтам — avcC и т.п. стоят глубоко). */
function findBox(bytes, type) {
  const t = [...type].map((c) => c.charCodeAt(0));
  for (let i = 4; i + 4 <= bytes.length; i += 1) {
    if (bytes[i] === t[0] && bytes[i + 1] === t[1] && bytes[i + 2] === t[2] && bytes[i + 3] === t[3]) {
      return i - 4;
    }
  }
  return -1;
}

/** MIME для MediaSource по avcC / mp4a, или ''. */
function mp4Mime(bytes) {
  const codecs = [];
  const avcc = findBox(bytes, 'avcC');
  if (avcc >= 0) {
    const hex = (b) => b.toString(16).padStart(2, '0');
    codecs.push(`avc1.${hex(bytes[avcc + 9])}${hex(bytes[avcc + 10])}${hex(bytes[avcc + 11])}`);
  }
  if (findBox(bytes, 'mp4a') >= 0) codecs.push('mp4a.40.2');
  if (findBox(bytes, 'Opus') >= 0) codecs.push('opus');
  return codecs.length ? `video/mp4; codecs="${codecs.join(', ')}"` : '';
}

// ------------------------------------------------------------ проигрывание
/** Фрагментированный MP4 подряд в одном <video> через MediaSource. */
class SourcePlayer {
  constructor(video, mime) {
    this.video = video;
    this.queue = [];
    this.ms = new MediaSource();
    this.url = URL.createObjectURL(this.ms);
    video.src = this.url;
    this.ready = new Promise((resolve) => {
      this.ms.addEventListener('sourceopen', () => {
        this.sb = this.ms.addSourceBuffer(mime);
        this.sb.mode = 'sequence';
        this.sb.addEventListener('updateend', () => this.pump());
        resolve();
      }, { once: true });
    });
  }

  async push(media) {
    await this.ready;
    this.queue.push(media);
    this.pump();
  }

  pump() {
    if (!this.sb || this.sb.updating || !this.queue.length) return;
    // Позади текущего места держать не больше нескольких секунд.
    const t = this.video.currentTime;
    if (this.sb.buffered.length && t - this.sb.buffered.start(0) > 10) {
      this.sb.remove(0, t - 5);
      return;
    }
    this.sb.appendBuffer(this.queue.shift());
    if (this.video.paused) this.video.play().catch(() => {});
  }

  close() {
    URL.revokeObjectURL(this.url);
    this.video.removeAttribute('src');
    this.video.load();
  }
}

/** Запасной путь: каждый кусок — свой файл, два <video> по очереди. */
class ChainPlayer {
  constructor(a, b) {
    this.v = [a, b];
    this.cur = 0;
    this.queue = [];
    this.playing = false;
    for (const v of this.v) v.addEventListener('ended', () => this.next());
  }

  push(media) {
    this.queue.push(URL.createObjectURL(new Blob([media], { type: 'video/mp4' })));
    if (!this.playing) this.next();
    else this.preload();
  }

  preload() {
    const other = this.v[1 - this.cur];
    if (!other.dataset.ready && this.queue.length) {
      other.src = this.queue.shift();
      other.dataset.ready = '1';
      other.load();
    }
  }

  next() {
    const shown = this.v[this.cur];
    const other = this.v[1 - this.cur];
    if (!other.dataset.ready) {
      if (!this.queue.length) {
        this.playing = false;
        return;
      }
      this.preload();
    }
    if (shown.src) URL.revokeObjectURL(shown.src);
    delete shown.dataset.ready;
    shown.hidden = true;
    other.hidden = false;
    delete other.dataset.ready;
    other.play().catch(() => {});
    this.cur = 1 - this.cur;
    this.playing = true;
    this.preload();
  }

  close() {
    for (const v of this.v) {
      if (v.src) URL.revokeObjectURL(v.src);
      v.removeAttribute('src');
      v.load();
    }
    for (const u of this.queue) URL.revokeObjectURL(u);
    this.queue = [];
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
  const videoA = el('video', { class: 'live__video', playsInline: true });
  const videoB = el('video', { class: 'live__video', playsInline: true, hidden: true });
  const note = el('div', { class: 'live__note' });
  const stage = el('div', { class: 'live__stage' }, videoA, videoB, note);
  const full = btn('call__btn--toggle', el('span', { class: 'icon call__glyph', textContent: '⛶' }),
    'Full screen', () => {
      if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
      else stage.requestFullscreen().catch(() => {});
    });
  const leave = btn('call__btn--hangup', icon('close'), 'Leave', () => close(true));
  root.append(el('div', { class: 'vchat__card live__card' },
    el('div', { class: 'vchat__head' }, el('div', { class: 'vchat__who' }, title, count), status),
    stage,
    el('div', { class: 'call__actions' }, full, leave)));
  ui = { title, count, status, videoA, videoB, note, stage };
}

function render() {
  if (!state) {
    root.hidden = true;
    return;
  }
  if (!ui) build();
  root.hidden = false;
  ui.title.textContent = state.title || 'Live stream';
  ui.count.textContent = `${state.count ?? 0} ${state.count === 1 ? 'viewer' : 'viewers'}`;
  ui.status.textContent = state.status ?? '';
  const live = state.mode === 'playing';
  ui.stage.classList.toggle('is-live', live);
  ui.note.hidden = live;
  ui.note.textContent = state.mode === 'waiting'
    ? `${state.title || 'This chat'} is not streaming right now.`
    : 'Connecting...';
  // Поворот кадра из заголовка куска — классом (style запрещён).
  for (const r of [90, 180, 270]) ui.stage.classList.toggle(`is-rot-${r}`, state.rotation === r);
}

// ------------------------------------------------------------ конвейер
const alive = (gen) => state && state.gen === gen;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const notReady = (e) => /Too Many Requests|TIME_TOO_BIG|FLOOD_WAIT|timed out/i.test(e?.message ?? '');

async function join(gen) {
  const pc = new RTCPeerConnection();
  try {
    pc.addTransceiver('audio', { direction: 'sendrecv' });
    pc.createDataChannel('data');
    await pc.setLocalDescription(await pc.createOffer());
    const local = parseLocal(pc.localDescription.sdp);
    if (!local.audioSsrc) local.audioSsrc = Math.floor(Math.random() * 0x7fffffff) + 1;
    const r = await call('vchat.join', {
      groupCallId: state.callId, ssrc: local.audioSsrc | 0,
      payload: JSON.stringify(joinPayload(local)), muted: true, video: false,
    });
    if (!alive(gen)) return false;
    state.joined = true;
    let answer = {};
    try { answer = JSON.parse(r.payload || '{}'); } catch { /* не JSON — не поток */ }
    return Boolean(answer.stream);
  } finally {
    pc.close();
  }
}

/** Конец потока (мс) или 0 — эфир не идёт. */
async function streamEnd() {
  try {
    const r = await call('vchat.streams', { groupCallId: state.callId });
    const list = r?.streams ?? [];
    const ch = list.find((s) => s.channelId === 1) ?? list[0];
    return ch ? Number(ch.timeOffset) || 0 : 0;
  } catch (e) {
    if (/GROUPCALL_JOIN_MISSING|GROUPCALL_FORBIDDEN/.test(e?.message ?? '')) state.joined = false;
    return 0;
  }
}

async function run(gen) {
  state.mode = 'connecting';
  render();
  try {
    if (!(await join(gen))) {
      if (!alive(gen)) return;
      hooks.notice?.('This live stream cannot be played here yet');
      close(true);
      return;
    }
  } catch (e) {
    report(e);
    close(false);
    return;
  }
  while (alive(gen)) {
    if (!state.joined) {
      try { await join(gen); } catch (e) { report(e); }
    }
    const end = await streamEnd();
    if (!alive(gen)) return;
    if (end <= 0) {
      state.mode = 'waiting';
      render();
      await sleep(STREAM_POLL_MS);
      continue;
    }
    await play(gen, Math.floor(end / STREAM_SEGMENT_MS) * STREAM_SEGMENT_MS - STREAM_BUFFER_MS);
  }
}

/** Куски подряд, пока идут; вернуться — значит, эфир пропал. */
async function play(gen, from) {
  let ts = from;
  let stalledSince = 0;
  while (alive(gen)) {
    let data;
    try {
      data = (await call('vchat.segment', {
        groupCallId: state.callId, timeOffset: String(ts), scale: 0, channelId: 1, quality: 'full',
      })).data;
    } catch (e) {
      if (!alive(gen)) return;
      if (notReady(e)) {
        stalledSince ||= Date.now();
        if (Date.now() - stalledSince > STREAM_STALL_MS) return;
        await sleep(STREAM_RETRY_MS);
        continue;
      }
      if (/GROUPCALL_JOIN_MISSING|GROUPCALL_FORBIDDEN/.test(e?.message ?? '')) state.joined = false;
      return;
    }
    stalledSince = 0;
    ts += STREAM_SEGMENT_MS;
    if (!alive(gen) || !data) continue;
    const part = parsePart(b64bytes(data));
    if (!part) {
      hooks.log?.('livestream: unknown part', data.slice(0, 40));
      continue;
    }
    feed(part);
  }
}

function feed(part) {
  if (!state.player) {
    const top = boxes(part.media).map((b) => b.type);
    const mime = mp4Mime(part.media);
    const fragmented = top.includes('moof');
    console.debug('[livestream] container', part.container, 'boxes', top.join(','), 'mime', mime);
    state.player = fragmented && mime && window.MediaSource?.isTypeSupported(mime)
      ? new SourcePlayer(ui.videoA, mime)
      : new ChainPlayer(ui.videoA, ui.videoB);
  }
  state.rotation = part.rotation;
  if (state.mode !== 'playing') {
    state.mode = 'playing';
    render();
  }
  state.player.push(part.media);
}

// ------------------------------------------------------------ вход и выход
function close(leave) {
  if (!state) return;
  const id = state.callId;
  const joined = state.joined;
  state.player?.close();
  state = null;
  render();
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  if (leave && joined) call('vchat.leave', { groupCallId: id }).catch(() => {});
}

/** { chatId, title, callId, call } — из ui/videochat.js (call.rtmp). */
export function openLiveStream(args) {
  if (state) {
    if (state.callId === args.callId) return;
    close(true);
  }
  state = {
    chatId: args.chatId, title: args.title, callId: args.callId,
    count: args.call?.count ?? 0, gen: Symbol('live'), mode: 'connecting',
    joined: false, player: null, rotation: 0,
  };
  render();
  run(state.gen).catch(report);
}

export function mountLiveStream(options) {
  hooks = options ?? {};
  root = el('div', { class: 'call vchat live', hidden: true, role: 'dialog', 'aria-label': 'Live stream' });
  document.body.append(root);
  on('srv:vchat', (c) => {
    if (!state || !c || c.id !== state.callId) return;
    state.count = c.count;
    if (!c.active) {
      hooks.notice?.('The live stream has ended');
      close(false);
      return;
    }
    render();
  });
}
