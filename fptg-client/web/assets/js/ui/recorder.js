import { el, clear } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { oggOpus, waveform5bit } from '../util/ogg.js';
import { micConstraints, cameraConstraints, micGain } from '../calls/devices.js';
import { uploadFile } from './attach.js';
import { startUpload, stopAction } from './sendaction.js';

// Голосовые и видеосообщения («кружки») — кнопка справа от поля ввода,
// как у Telegram Desktop:
//   щелчок — переключить голос/видео (запоминается);
//   нажать и держать — запись; отпустить — отправить; отпустить вне поля
//     ввода — отменить; Escape — отменить;
//   потянуть вверх — замок: запись идёт без кнопки, квадрат — стоп и
//     прослушивание (корзина — удалить, стрелка — отправить).
//
// Голос — OGG/Opus, один канал (td_api.tl, inputVoiceNote): пакеты даёт
// AudioEncoder (WebCodecs), контейнер — util/ogg.js; волна — 100 значений
// по 5 бит. Кружок — квадрат LENGTH со всего кадра камеры (центр), MPEG4
// H.264 + AAC из MediaRecorder, до 60 с, миниатюра JPEG.

const MODE_KEY = 'fptg.recordMode';
// Удержание дольше — запись; короче — щелчок (переключение вида).
const HOLD_MS = 220;
// На сколько потянуть вверх, чтобы встал замок.
const LOCK_PX = 60;
const LOCK_SIDE_PX = 48;
// Короче — не отправлять (случайное нажатие), как у Desktop.
const MIN_SECONDS = 0.6;
const VIDEO_MAX_SECONDS = 60;
const VOICE_MAX_SECONDS = 3600;
// Сторона кружка и миниатюры (td_api.tl: length <= 640, миниатюра <= 320).
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
let rec = null;               // текущая запись (VoiceRec / VideoRec)
let result = null;            // остановленная запись (для прослушивания)
let holdTimer = 0;
let tick = 0;
let startY = 0;
let startX = 0;
let player = null;

try {
  mode = localStorage.getItem(MODE_KEY) === 'video' ? 'video' : 'voice';
} catch {
  // без хранилища — голос
}

// ------------------------------------------------------------- голос

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

  /** Кадр звука -> моно (первый канал), пик для волны, кодировщик. */
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
            // Задержка кодировщика — из его OpusHead, если он его дал.
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
    try { this.encoder?.close(); } catch { /* уже закрыт */ }
  }
}

// ------------------------------------------------------------- кружок

class VideoRec {
  async start() {
    if (!MediaRecorder.isTypeSupported(VIDEO_TYPE)) throw new Error('This window cannot record MP4 video');
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: cameraConstraints({ width: { ideal: 720 }, height: { ideal: 720 } }),
      audio: micConstraints({ echoCancellation: true, noiseSuppression: true }),
    });
    this.video = el('video', { class: 'recorder-video__live', muted: true, autoplay: true, playsInline: true });
    this.video.srcObject = this.stream;
    await this.video.play().catch(() => {});
    this.canvas = el('canvas', { width: LENGTH, height: LENGTH });
    this.g = this.canvas.getContext('2d');
    this.draw();
    // Кадр — по таймеру: rAF у скрытого окна замирает.
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
    // Миниатюра — с первых кадров.
    this.thumb = new Promise((resolve) => setTimeout(() => {
      const c = el('canvas', { width: THUMB, height: THUMB });
      c.getContext('2d').drawImage(this.canvas, 0, 0, THUMB, THUMB);
      c.toBlob((b) => resolve(b), 'image/jpeg', 0.8);
    }, 400));
    return this.video;
  }

  /** Квадрат из середины кадра камеры. */
  draw() {
    const v = this.video;
    if (!v || !v.videoWidth) return;
    const side = Math.min(v.videoWidth, v.videoHeight);
    this.g.drawImage(v, (v.videoWidth - side) / 2, (v.videoHeight - side) / 2, side, side, 0, 0, LENGTH, LENGTH);
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
    try { if (this.rec?.state !== 'inactive') this.rec.stop(); } catch { /* уже */ }
    this.release();
  }
}

// ------------------------------------------------------------ вид

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
    setButton('videonote', 'Video message\nHold to record, click to switch to voice message');
  } else {
    setButton('mic', 'Voice message\nHold to record, click to switch to video message');
  }
}

function setLevel(value) {
  // Пульсация кнопки — ступенями-классами (style в коде не пишем).
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

// --------------------------------------------------------- ход записи

async function begin() {
  if (state !== 'holding') return;
  state = 'starting';
  rec = mode === 'video' ? new VideoRec() : new VoiceRec();
  try {
    const live = await rec.start();
    if (mode === 'video') {
      videoBox = el('div', { class: 'recorder-video' }, el('div', { class: 'recorder-video__circle' }, live));
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
  // Отпустили, пока запускалось.
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
    // Предел — как у Desktop: остановить и отправить.
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

/** Остановить: send — сразу отправить, иначе — прослушать. */
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

/** Прослушать перед отправкой: проигрывание, волна, длительность. */
function preview() {
  state = 'preview';
  // Запись кончилась — без кольца громкости.
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

/** Загрузить и отправить (message.sendNote через main.js). */
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

// ---------------------------------------------------------- кнопка

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
  // Замок — только строго вверх, к значку над кнопкой; в сторону с поля
  // — это отмена при отпускании, как у Desktop.
  if (state === 'recording' && startY - event.clientY > LOCK_PX
      && Math.abs(event.clientX - startX) < LOCK_SIDE_PX) lock();
}

function onUp(event) {
  clearTimeout(holdTimer);
  if (state === 'holding') {
    // Щелчок — другой вид, как у Desktop.
    state = 'idle';
    mode = mode === 'voice' ? 'video' : 'voice';
    try { localStorage.setItem(MODE_KEY, mode); } catch { /* без хранилища */ }
    idleButton();
    return;
  }
  if (state === 'starting') {
    state = 'idle';       // begin увидит и отменит
    return;
  }
  if (state !== 'recording') return;
  // Отпустили вне поля ввода — отмена.
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

/** Чат сменился — незаконченная запись пропадает (как у Desktop). */
export function cancelRecording() {
  if (state !== 'idle') cancel();
}
