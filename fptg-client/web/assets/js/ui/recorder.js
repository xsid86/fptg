import { el, clear } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { oggOpus, waveform5bit } from '../util/ogg.js';
import { micConstraints, cameraConstraints, micGain } from '../calls/devices.js';
import { uploadFile } from './attach.js';
import { startUpload, stopAction } from './sendaction.js';

// Voice and video messages ("round videos") — the button to the right of
// the input field, as in Telegram Desktop:
//   a click — switch voice/video (remembered);
//   press and hold — recording; release — send; release outside the input
//     field — cancel; Escape — cancel;
//   drag up — the lock: recording goes on without the button, the square —
//     stop and listen (the bin — delete, the arrow — send).
//
// Voice — OGG/Opus, one channel (td_api.tl, inputVoiceNote): AudioEncoder
// (WebCodecs) gives the packets, the container — util/ogg.js; the waveform
// — 100 values of 5 bits. A round video — a LENGTH square from the whole
// camera frame (the centre), MPEG4 H.264 + AAC from MediaRecorder, up to
// 60 s, a JPEG thumbnail.

const MODE_KEY = 'fptg.recordMode';
// Holding longer — recording; shorter — a click (switching the kind).
const HOLD_MS = 220;
// How far to drag up for the lock to engage.
const LOCK_PX = 60;
const LOCK_SIDE_PX = 48;
// Shorter — do not send (an accidental press), as in Desktop.
const MIN_SECONDS = 0.6;
const VIDEO_MAX_SECONDS = 60;
const VOICE_MAX_SECONDS = 3600;
// The side of the round video and the thumbnail (td_api.tl: length <= 640, thumbnail <= 320).
const LENGTH = 400;
const THUMB = 320;
const VIDEO_TYPE = 'video/mp4;codecs=avc1.42E01E,mp4a.40.2';
const TICK_MS = 50;

let hooks = {};
let composer = null;
let button = null;
let overlay = null;
let lockHint = null;
let videoBox = null;
let mode = 'voice';
let state = 'idle';           // idle | holding | recording | locked | preview | sending
let rec = null;               // the current recording (VoiceRec / VideoRec)
let result = null;            // a stopped recording (for listening)
let holdTimer = 0;
let tick = 0;
let startY = 0;
let startX = 0;
let player = null;

try {
  mode = localStorage.getItem(MODE_KEY) === 'video' ? 'video' : 'voice';
} catch {
  // without storage — voice
}

// ------------------------------------------------------------- voice

class VoiceRec {
  async start() {
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: micConstraints({ echoCancellation: true, noiseSuppression: true, autoGainControl: true }),
      video: false,
    });
    this.ctx = new AudioContext({ sampleRate: 48000 });
    if (this.ctx.state === 'suspended') await this.ctx.resume().catch(() => {});
    const src = this.ctx.createMediaStreamSource(this.stream);
    const gain = this.ctx.createGain();
    gain.gain.value = micGain();
    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 1024;
    const dst = this.ctx.createMediaStreamDestination();
    dst.channelCount = 1;
    dst.channelCountMode = 'explicit';
    src.connect(gain);
    gain.connect(this.analyser);
    gain.connect(dst);
    this.packets = [];
    this.peaks = [];
    this.preSkip = 312;
    this.samples = 0;
    this.encoder = null;
    this.failed = null;
    const track = dst.stream.getAudioTracks()[0];
    this.reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
    this.pump = this.read();
  }

  async read() {
    for (;;) {
      let chunk;
      try {
        chunk = await this.reader.read();
      } catch {
        return;
      }
      if (chunk.done) return;
      this.feed(chunk.value);
    }
  }

  /** A sound frame -> mono (the first channel), the peak for the waveform, the encoder. */
  feed(data) {
    try {
      const frames = data.numberOfFrames;
      const plane = new Float32Array(frames);
      data.copyTo(plane, { planeIndex: 0, format: 'f32-planar' });
      let peak = 0;
      for (let i = 0; i < frames; i += 1) peak = Math.max(peak, Math.abs(plane[i]));
      this.peaks.push(peak);
      if (!this.encoder) {
        this.encoder = new AudioEncoder({
          output: (chunk, meta) => {
            const bytes = new Uint8Array(chunk.byteLength);
            chunk.copyTo(bytes);
            const samples = chunk.duration ? Math.round((chunk.duration * 48000) / 1e6) : 960;
            this.packets.push({ data: bytes, samples });
            this.samples += samples;
            // The encoder's delay — from its OpusHead, if it gave one.
            const d = meta?.decoderConfig?.description;
            if (d && d.byteLength >= 12) {
              const v = new DataView(d instanceof ArrayBuffer ? d : d.buffer, d.byteOffset ?? 0);
              this.preSkip = v.getUint16(10, true);
            }
          },
          error: (e) => { this.failed = e; },
        });
        this.encoder.configure({ codec: 'opus', sampleRate: data.sampleRate, numberOfChannels: 1, bitrate: 32000 });
      }
      const mono = new AudioData({
        format: 'f32-planar', sampleRate: data.sampleRate, numberOfFrames: frames,
        numberOfChannels: 1, timestamp: data.timestamp, data: plane,
      });
      this.encoder.encode(mono);
      mono.close();
    } finally {
      data.close();
    }
  }

  level() {
    if (!this.analyser) return 0;
    const buf = new Float32Array(this.analyser.fftSize);
    this.analyser.getFloatTimeDomainData(buf);
    let sum = 0;
    for (const v of buf) sum += v * v;
    return Math.sqrt(sum / buf.length);
  }

  release() {
    for (const t of this.stream?.getTracks() ?? []) t.stop();
    this.reader?.cancel().catch(() => {});
    this.ctx?.close().catch(() => {});
  }

  async stop() {
    this.release();
    await this.pump;
    if (this.encoder && this.encoder.state === 'configured') await this.encoder.flush().catch(() => {});
    this.encoder?.close();
    if (this.failed) throw this.failed;
    const wave = waveform5bit(this.peaks);
    return {
      kind: 'voice',
      blob: oggOpus(this.packets, { preSkip: this.preSkip }),
      duration: this.samples / 48000,
      waveform: wave.base64,
      bars: wave.values,
    };
  }

  cancel() {
    this.release();
    try { this.encoder?.close(); } catch { /* already closed */ }
  }
}

// ------------------------------------------------------------- round video

class VideoRec {
  async start() {
    if (!MediaRecorder.isTypeSupported(VIDEO_TYPE)) throw new Error('This window cannot record MP4 video');
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: cameraConstraints({ width: { ideal: 720 }, height: { ideal: 720 } }),
      audio: micConstraints({ echoCancellation: true, noiseSuppression: true }),
    });
    this.video = el('video', { muted: true, autoplay: true, playsInline: true });
    this.video.srcObject = this.stream;
    // Do not wait: without frames from the camera play() does not finish,
    // and the recording would hang at the start; frames appear — draw picks them up.
    this.video.play().catch(() => {});
    // The preview is the recording canvas itself (mirrored in CSS): exactly
    // what will go out is visible; until the camera gives a frame — our own arc.
    this.canvas = el('canvas', { class: 'recorder-video__live', width: LENGTH, height: LENGTH });
    this.g = this.canvas.getContext('2d');
    this.hasFrame = false;
    this.draw();
    // A frame — by a timer: rAF freezes in a hidden window.
    this.drawTimer = setInterval(() => this.draw(), 1000 / 30);
    const audio = new AudioContext();
    this.ctx = audio;
    this.analyser = audio.createAnalyser();
    this.analyser.fftSize = 1024;
    audio.createMediaStreamSource(this.stream).connect(this.analyser);
    const out = new MediaStream([
      ...this.canvas.captureStream(30).getVideoTracks(),
      ...this.stream.getAudioTracks(),
    ]);
    this.chunks = [];
    this.rec = new MediaRecorder(out, { mimeType: VIDEO_TYPE, videoBitsPerSecond: 1_000_000, audioBitsPerSecond: 64_000 });
    this.rec.addEventListener('dataavailable', (e) => { if (e.data.size) this.chunks.push(e.data); });
    this.rec.start(500);
    this.startedAt = performance.now();
    // The thumbnail — from the first frames.
    this.thumb = new Promise((resolve) => setTimeout(() => {
      const c = el('canvas', { width: THUMB, height: THUMB });
      c.getContext('2d').drawImage(this.canvas, 0, 0, THUMB, THUMB);
      c.toBlob((b) => resolve(b), 'image/jpeg', 0.8);
    }, 400));
    return this.canvas;
  }

  /** A square from the middle of the camera frame. */
  draw() {
    const v = this.video;
    if (!v || !v.videoWidth) return;
    const side = Math.min(v.videoWidth, v.videoHeight);
    this.g.drawImage(v, (v.videoWidth - side) / 2, (v.videoHeight - side) / 2, side, side, 0, 0, LENGTH, LENGTH);
    if (!this.hasFrame) {
      this.hasFrame = true;
      this.onFrame?.();
    }
  }

  level() {
    if (!this.analyser) return 0;
    const buf = new Float32Array(this.analyser.fftSize);
    this.analyser.getFloatTimeDomainData(buf);
    let sum = 0;
    for (const v of buf) sum += v * v;
    return Math.sqrt(sum / buf.length);
  }

  release() {
    clearInterval(this.drawTimer);
    for (const t of this.stream?.getTracks() ?? []) t.stop();
    this.ctx?.close().catch(() => {});
  }

  async stop() {
    const duration = (performance.now() - this.startedAt) / 1000;
    const done = new Promise((resolve) => this.rec.addEventListener('stop', resolve, { once: true }));
    if (this.rec.state !== 'inactive') this.rec.stop();
    await done;
    this.release();
    return {
      kind: 'video',
      blob: new Blob(this.chunks, { type: 'video/mp4' }),
      thumb: await this.thumb,
      duration: Math.min(duration, VIDEO_MAX_SECONDS),
    };
  }

  cancel() {
    try { if (this.rec?.state !== 'inactive') this.rec.stop(); } catch { /* already */ }
    this.release();
  }
}

// ------------------------------------------------------------ view

const fmtTime = (s) => {
  const m = Math.floor(s / 60);
  const sec = Math.floor(s % 60);
  const cs = Math.floor((s * 100) % 100);
  return `${m}:${String(sec).padStart(2, '0')},${String(cs).padStart(2, '0')}`;
};

function setButton(name, title) {
  clear(button).append(icon(name), el('span', { class: 'u-sr-only' }, title));
  button.title = title;
}

function idleButton() {
  if (mode === 'video') {
    setButton('video', 'Video message\nHold to record, click to switch to voice message');
  } else {
    setButton('mic', 'Voice message\nHold to record, click to switch to video message');
  }
}

function setLevel(value) {
  // The button's pulsing — in class steps (we do not write style in code).
  const step = Math.min(5, Math.round(Math.min(1, value * 6) * 5));
  for (let i = 0; i <= 5; i += 1) button.classList.toggle(`is-level-${i}`, i === step);
}

function showOverlay(kind) {
  composer.classList.add('is-recording');
  overlay.hidden = false;
  clear(overlay);
  if (kind === 'recording' || kind === 'locked') {
    const time = el('span', { class: 'recorder__time u-tabular' }, '0:00,00');
    const parts = [el('span', { class: 'recorder__dot' }), time];
    if (kind === 'recording') {
      parts.push(el('span', { class: 'recorder__hint' }, 'Release outside this field to cancel'));
    } else {
      parts.unshift(el('button', {
        class: 'btn btn--icon recorder__trash', type: 'button', title: 'Delete', onclick: cancel,
      }, icon('trash')));
      parts.push(el('span', { class: 'recorder__hint' }, 'Click the button to stop'));
    }
    overlay.append(...parts);
    return time;
  }
  return null;
}

function hideOverlay() {
  composer.classList.remove('is-recording', 'is-locked');
  overlay.hidden = true;
  lockHint.hidden = true;
  clear(overlay);
  setLevel(-1);
  button.classList.remove('is-recording');
  if (videoBox) {
    videoBox.remove();
    videoBox = null;
  }
  idleButton();
}

// --------------------------------------------------------- recording flow

async function begin() {
  if (state !== 'holding') return;
  state = 'starting';
  rec = mode === 'video' ? new VideoRec() : new VoiceRec();
  try {
    const live = await rec.start();
    if (mode === 'video') {
      // While there is no frame from the camera — our own steady arc (.recorder-video__wait).
      videoBox = el('div', { class: `recorder-video${rec.hasFrame ? '' : ' is-waiting'}` },
        el('div', { class: 'recorder-video__circle' }, live,
          el('span', { class: 'recorder-video__wait', 'aria-hidden': 'true' })));
      const box = videoBox;
      rec.onFrame = () => box.classList.remove('is-waiting');
      composer.append(videoBox);
    }
  } catch (error) {
    rec?.cancel();
    rec = null;
    state = 'idle';
    hideOverlay();
    hooks.report(error?.name === 'NotAllowedError' ? 'No access to the microphone or camera' : (error?.message || String(error)));
    return;
  }
  // Released while it was starting.
  if (state !== 'starting') {
    rec.cancel();
    rec = null;
    return;
  }
  state = 'recording';
  startUpload(mode === 'video' ? 'recordVideo' : 'recordVoice');
  button.classList.add('is-recording');
  lockHint.hidden = false;
  const time = showOverlay('recording');
  const startedAt = performance.now();
  const max = mode === 'video' ? VIDEO_MAX_SECONDS : VOICE_MAX_SECONDS;
  clearInterval(tick);
  tick = setInterval(() => {
    const s = (performance.now() - startedAt) / 1000;
    const t = overlay.querySelector('.recorder__time');
    if (t) t.textContent = fmtTime(s);
    setLevel(rec?.level() ?? 0);
    // The limit — as in Desktop: stop and send.
    if (s >= max && (state === 'recording' || state === 'locked')) finish(true);
  }, TICK_MS);
  return time;
}

function lock() {
  if (state !== 'recording') return;
  state = 'locked';
  composer.classList.add('is-locked');
  lockHint.hidden = true;
  showOverlay('locked');
  setButton('stop', 'Stop');
}

/** Stop: send — send at once, otherwise — listen. */
async function finish(send) {
  if (!rec || (state !== 'recording' && state !== 'locked')) return;
  clearInterval(tick);
  state = 'sending';
  stopAction();
  const r = rec;
  rec = null;
  let out;
  try {
    out = await r.stop();
  } catch (error) {
    hideOverlay();
    state = 'idle';
    hooks.report(error);
    return;
  }
  if (out.duration < MIN_SECONDS) {
    hideOverlay();
    state = 'idle';
    return;
  }
  if (send) {
    hideOverlay();
    state = 'idle';
    await deliver(out);
  } else {
    result = out;
    preview();
  }
}

function cancel() {
  clearInterval(tick);
  rec?.cancel();
  rec = null;
  result = null;
  player?.pause();
  player = null;
  stopAction();
  state = 'idle';
  hideOverlay();
}

/** Listen before sending: playback, the waveform, the duration. */
function preview() {
  state = 'preview';
  // The recording ended — without the volume ring.
  button.classList.remove('is-recording');
  setLevel(-1);
  composer.classList.add('is-recording', 'is-locked');
  overlay.hidden = false;
  clear(overlay);
  const url = URL.createObjectURL(result.blob);
  const play = el('button', { class: 'btn btn--icon recorder__play', type: 'button', title: 'Play' }, icon('play'));
  if (result.kind === 'voice') {
    player = el('audio', { src: url });
    const bars = el('span', { class: 'recorder__wave' },
      ...result.bars.filter((_, i) => i % 2 === 0).map((v) => el('i', { class: `recorder__bar recorder__bar--${v}` })));
    overlay.append(
      el('button', { class: 'btn btn--icon recorder__trash', type: 'button', title: 'Delete', onclick: cancel }, icon('trash')),
      play, bars, el('span', { class: 'recorder__time u-tabular' }, fmtTime(result.duration)));
  } else {
    player = el('video', { class: 'recorder-video__live is-recorded', src: url, playsInline: true, loop: true });
    videoBox?.remove();
    videoBox = el('div', { class: 'recorder-video' }, el('div', { class: 'recorder-video__circle' }, player));
    composer.append(videoBox);
    overlay.append(
      el('button', { class: 'btn btn--icon recorder__trash', type: 'button', title: 'Delete', onclick: cancel }, icon('trash')),
      play, el('span', { class: 'recorder__time u-tabular' }, fmtTime(result.duration)));
  }
  play.addEventListener('click', () => {
    if (player.paused) player.play().catch(() => {});
    else player.pause();
  });
  player.addEventListener('play', () => clear(play).append(icon('pause')));
  player.addEventListener('pause', () => clear(play).append(icon('play')));
  player.addEventListener('ended', () => clear(play).append(icon('play')));
  setButton('send', 'Send');
}

/** Upload and send (message.sendNote through main.js). */
async function deliver(out) {
  try {
    if (out.kind === 'voice') {
      const file = await uploadFile(new File([out.blob], 'voice.ogg', { type: 'audio/ogg' }));
      emit('ui:send-note', {
        kind: 'voice', file, duration: Math.max(1, Math.round(out.duration)), waveform: out.waveform,
        replyTo: hooks.takeReply(), silent: hooks.isSilent(),
      });
    } else {
      const file = await uploadFile(new File([out.blob], 'video.mp4', { type: 'video/mp4' }));
      const thumb = out.thumb ? await uploadFile(new File([out.thumb], 'thumb.jpg', { type: 'image/jpeg' })) : '';
      emit('ui:send-note', {
        kind: 'video', file, thumb, tw: THUMB, th: THUMB, length: LENGTH,
        duration: Math.max(1, Math.round(out.duration)),
        replyTo: hooks.takeReply(), silent: hooks.isSilent(),
      });
    }
  } catch (error) {
    hooks.report(error);
  }
}

// ---------------------------------------------------------- button

function onDown(event) {
  if (event.button !== 0 || !hooks.canCompose()) return;
  event.preventDefault();
  if (state === 'locked') {
    finish(false);
    return;
  }
  if (state === 'preview') {
    const out = result;
    result = null;
    player?.pause();
    player = null;
    state = 'idle';
    hideOverlay();
    deliver(out);
    return;
  }
  if (state !== 'idle') return;
  button.setPointerCapture(event.pointerId);
  startY = event.clientY;
  startX = event.clientX;
  state = 'holding';
  holdTimer = setTimeout(begin, HOLD_MS);
}

function onMove(event) {
  // The lock — only straight up, to the icon above the button; sideways off
  // the field — that is a cancel on release, as in Desktop.
  if (state === 'recording' && startY - event.clientY > LOCK_PX
      && Math.abs(event.clientX - startX) < LOCK_SIDE_PX) lock();
}

function onUp(event) {
  clearTimeout(holdTimer);
  if (state === 'holding') {
    // A click — the other kind, as in Desktop.
    state = 'idle';
    mode = mode === 'voice' ? 'video' : 'voice';
    try { localStorage.setItem(MODE_KEY, mode); } catch { /* without storage */ }
    idleButton();
    return;
  }
  if (state === 'starting') {
    state = 'idle';       // begin will see it and cancel
    return;
  }
  if (state !== 'recording') return;
  // Released outside the input field — a cancel.
  const r = composer.getBoundingClientRect();
  const inside = event.clientX >= r.left && event.clientX <= r.right
    && event.clientY >= r.top && event.clientY <= r.bottom;
  if (inside) finish(true);
  else cancel();
}

/**
 * composerNode — #composer; options: { canCompose(), takeReply(),
 * isSilent(), report(err) }.
 */
export function mountRecorder(composerNode, options) {
  hooks = options;
  composer = composerNode;
  const row = composer.querySelector('.composer__row');
  button = el('button', { class: 'composer__record', type: 'button' });
  button.addEventListener('pointerdown', onDown);
  button.addEventListener('pointermove', onMove);
  button.addEventListener('pointerup', onUp);
  button.addEventListener('pointercancel', () => { clearTimeout(holdTimer); if (state === 'recording') cancel(); });
  lockHint = el('span', { class: 'recorder__lock', hidden: true }, icon('lock'), icon('chevron-down'));
  overlay = el('div', { class: 'recorder', hidden: true });
  row.append(overlay, el('span', { class: 'composer__record-box' }, lockHint, button));
  idleButton();
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && state !== 'idle') cancel();
  });
}

/** The chat changed — an unfinished recording is lost (as in Desktop). */
export function cancelRecording() {
  if (state !== 'idle') cancel();
}
