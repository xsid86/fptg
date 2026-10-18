import { el, clear } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { parseLocal, joinPayload } from '../calls/group.js';

// The live stream window — an RTMP broadcast of a channel or group
// (groupCall.is_rtmp_stream). The media goes not over WebRTC but in
// one-second pieces through TDLib (vchat.streams / vchat.segment,
// webapi.pas). The order is per the Telegram docs
// (core.telegram.org/api/group-calls, "RTMP mode") and tgcalls
// (StreamingMediaContext, VideoStreamingPart):
//
//  1. Join as a video chat (vchat.join): the WebRTC description is needed
//     only for the join payload, the PeerConnection itself closes at once —
//     the server answers {"stream":true,"rtmp":true}.
//  2. The channel list (getGroupCallStreams): empty or an error — the
//     broadcast is not on ("… is not streaming right now"), ask again later.
//     A live one has time_offset, the end of the stream; the start is
//     STREAM_BUFFER_MS earlier, on the STREAM_SEGMENT_MS grid.
//  3. The pieces of channel 1 (in RTMP — video and sound together), quality
//     full, scale 0 (a second), one after another. "Not ready" (FLOOD_WAIT /
//     TIME_TOO_BIG — in TDLib that is 429) — the same piece after
//     STREAM_RETRY_MS. Not ready for too long — back to step 2.
//
// A piece: the tgcalls header (signature 0xa12e810d, the container name, a
// mask, one event with an offset and rotation), followed by the container
// itself (by name: "mp4"). Fragmented MP4 goes into MediaSource one after
// another; a plain one — the fallback path: each piece in its own <video>,
// two in turn.
//
// VERIFIED LIVE: joining, the {"stream":true,"rtmp":true} answer, an empty
// broadcast (FLOOD_WAIT on the channel list — likewise "not streaming" in
// the official client). NOT VERIFIED: parsing and playing pieces — there
// was no broadcast with a picture.

const STREAM_SEGMENT_MS = 1000;
const STREAM_BUFFER_MS = 2000;
const STREAM_RETRY_MS = 100;
const STREAM_POLL_MS = 5000;           // the broadcast is not on — ask again after
const STREAM_STALL_MS = 10000;         // a piece not ready this long — the broadcast is gone
const PART_SIGNATURE = 0xa12e810d;

let hooks = {};
let root = null;
let ui = null;
let state = null;   // { chatId, title, callId, count, gen, ... }

const call = (cmd, args) => hooks.call(cmd, args);

function report(error) {
  hooks.report?.(error);
}

// ------------------------------------------------------------ piece
function b64bytes(s) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
  return out;
}

/** A tgcalls string: the length as a byte (254 — 3 length bytes follow), the bytes, alignment to 4. */
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

/** A piece's header -> { container, rotation, media } or null. */
export function parsePart(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.length < 8 || view.getUint32(0, true) !== PART_SIGNATURE) return null;
  const container = readString(view, bytes, 4);
  let pos = container.next;
  pos += 4;                                   // activeMask
  pos += 4;                                   // eventCount (tgcalls reads one event)
  const offset = view.getInt32(pos, true);
  const endpoint = readString(view, bytes, pos + 4);
  pos = endpoint.next;
  const rotation = view.getInt32(pos, true);
  pos += 8;                                   // rotation + extra
  if (offset < 0 || pos + offset > bytes.length) return null;
  return { container: container.text, rotation, media: bytes.subarray(pos + offset) };
}

// ------------------------------------------------------------ MP4
/** The top-level MP4 boxes: [{ type, start, size }]. */
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

/** The first box of type inside (a byte search — avcC and the like sit deep). */
function findBox(bytes, type) {
  const t = [...type].map((c) => c.charCodeAt(0));
  for (let i = 4; i + 4 <= bytes.length; i += 1) {
    if (bytes[i] === t[0] && bytes[i + 1] === t[1] && bytes[i + 2] === t[2] && bytes[i + 3] === t[3]) {
      return i - 4;
    }
  }
  return -1;
}

/** The MIME for MediaSource by avcC / mp4a, or ''. */
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

// ------------------------------------------------------------ playback
/** Fragmented MP4 one after another in one <video> through MediaSource. */
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
    // Keep no more than a few seconds behind the current position.
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

/** The fallback path: each piece is its own file, two <video> in turn. */
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

// ------------------------------------------------------------ view
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
  // The frame rotation from the piece header — by a class (style is forbidden).
  for (const r of [90, 180, 270]) ui.stage.classList.toggle(`is-rot-${r}`, state.rotation === r);
}

// ------------------------------------------------------------ pipeline
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
    try { answer = JSON.parse(r.payload || '{}'); } catch { /* not JSON — not a stream */ }
    return Boolean(answer.stream);
  } finally {
    pc.close();
  }
}

/** The end of the stream (ms) or 0 — the broadcast is not on. */
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

/** Pieces one after another while they come; returning means the broadcast is gone. */
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

// ------------------------------------------------------------ join and leave
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

/** { chatId, title, callId, call } — from ui/videochat.js (call.rtmp). */
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
