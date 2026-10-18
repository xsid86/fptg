// The choice of devices for calls: microphone, camera, speaker.
//
// The choice is in THIS page's localStorage, not in the server settings:
// device ids are the browser's, and on another machine (the front end apart
// from the server — Android, Linux) they mean something else or nothing.
// The storage may be unavailable — then simply the default devices.
//
// The browser gives the device names and the FULL list only after the
// microphone or camera was captured in this window session: before that —
// one nameless device of each kind ("Speaker 1"), though a person may have
// a dozen (a live case: 5 inputs and 7 outputs, one of each was visible).
// The host window allows its page the microphone without asking
// (webview2.pas), but the permission is not kept between runs. So the open
// device panel itself opens and at once closes the microphone once per
// session (unlockNames, ~0.1 s), and the list becomes full.

import { emit } from '../core/bus.js';
import { el } from '../core/dom.js';
import { trackFill, pruneFills } from '../util/rangefill.js';

const KEY = 'fptg.callDevices';

function read() {
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? '{}') ?? {};
  } catch {
    return {};
  }
}

function write(prefs) {
  try {
    localStorage.setItem(KEY, JSON.stringify(prefs));
  } catch {
    // without storage the choice lives until a reload
  }
}

let prefs = read();

export const chosen = (kind) => prefs[kind] ?? '';

/** Choose a device: kind — mic | camera | speaker, id '' — the default. */
export function choose(kind, id) {
  prefs = { ...prefs, [kind]: id };
  write(prefs);
  emit('calls:device', { kind, id });
  // Other open panels (the call window, the settings) — show the new choice.
  refreshAll();
}

/** getUserMedia constraints for sound with the chosen microphone. */
export function micConstraints(extra = {}) {
  const id = chosen('mic');
  return { ...extra, ...(id ? { deviceId: { ideal: id } } : {}) };
}

/** getUserMedia constraints for video with the chosen camera. */
export function cameraConstraints(extra = {}) {
  const id = chosen('camera');
  return { ...extra, ...(id ? { deviceId: { ideal: id } } : {}) };
}

// ------------------------------------------------------- volume
// Microphone: 0..MIC_GAIN_MAX — a WebAudio amplifier between the microphone
// and the call (openMic). Output: 0..1 — the volume of the other side's
// <audio>; above 100% — only through WebAudio, and then the output does not
// follow the chosen speaker (setSinkId belongs to the element), hence no gain.
export const MIC_GAIN_MAX = 2;
const live = new Set();     // the amplifiers of open microphones

export const micGain = () => prefs.micGain ?? 1;
export const outputVolume = () => prefs.volume ?? 1;

/** kind: 'mic' (0..MIC_GAIN_MAX) or 'speaker' (0..1). */
export function setLevel(kind, value) {
  if (kind === 'mic') {
    prefs = { ...prefs, micGain: value };
    for (const g of live) g.gain.value = value;
  } else {
    prefs = { ...prefs, volume: value };
    // call windows reapply the volume to their <audio> (routeAudio)
    emit('calls:device', { kind: 'speaker' });
  }
  write(prefs);
}

/**
 * The microphone through an amplifier: a MediaStream with one track. stop()
 * of that track ends both the real microphone and the amplifier — the
 * calling code stops it like an ordinary one.
 */
export async function openMic(constraints) {
  const raw = await navigator.mediaDevices.getUserMedia({ audio: constraints, video: false });
  let ctx;
  try {
    ctx = new AudioContext();
  } catch {
    return raw;   // without WebAudio — the microphone as it is
  }
  if (ctx.state === 'suspended') ctx.resume().catch(() => {});
  const gain = ctx.createGain();
  gain.gain.value = micGain();
  const dst = ctx.createMediaStreamDestination();
  ctx.createMediaStreamSource(raw).connect(gain).connect(dst);
  live.add(gain);
  const track = dst.stream.getAudioTracks()[0];
  const stop = track.stop.bind(track);
  track.stop = () => {
    stop();
    for (const t of raw.getTracks()) t.stop();
    live.delete(gain);
    ctx.close().catch(() => {});
  };
  return new MediaStream([track]);
}

/** Route the element's sound to the chosen speaker (if the browser can). */
export async function routeAudio(node) {
  const id = chosen('speaker');
  if (node) node.volume = Math.min(1, Math.max(0, outputVolume()));
  if (!node || typeof node.setSinkId !== 'function') return;
  try {
    await node.setSinkId(id);
  } catch {
    // the device is gone — what was there stays
  }
}

// The microphone was already opened in this session for the list — no need a second time.
let unlockTried = false;

/**
 * Open and at once close the microphone — after that the browser gives all
 * devices with names. Sound, not the camera: that is enough for cameras too
 * (measured), and the camera indicator does not blink. true — it worked.
 */
async function unlockNames() {
  if (unlockTried) return false;
  unlockTried = true;
  try {
    const s = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
    for (const t of s.getTracks()) t.stop();
    return true;
  } catch {
    return false;
  }
}

/** Devices by kind: { mic: [{id, label}], camera: [...], speaker: [...] }. */
export async function listDevices() {
  const out = { mic: [], camera: [], speaker: [] };
  let all = [];
  try {
    all = await navigator.mediaDevices.enumerateDevices();
  } catch {
    return out;
  }
  const map = { audioinput: 'mic', videoinput: 'camera', audiooutput: 'speaker' };
  const names = { mic: 'Microphone', camera: 'Camera', speaker: 'Speaker' };
  for (const d of all) {
    const kind = map[d.kind];
    if (!kind || d.deviceId === 'default' || d.deviceId === 'communications') continue;
    out[kind].push({ id: d.deviceId, label: d.label || `${names[kind]} ${out[kind].length + 1}` });
  }
  return out;
}

// ------------------------------------------------------------ panel
// Device choice and volume in one panel: the call window, the video chat
// window, the settings (the Calls section). There may be several open
// copies — a choice in one is seen at once in the others (refreshAll).
const panels = new Set();

function select(kind, devs) {
  const sel = el('select', { class: 'call-levels__select' });
  sel.append(el('option', { value: '' }, 'Default'));
  for (const d of devs[kind]) sel.append(el('option', { value: d.id }, d.label));
  sel.value = devs[kind].some((d) => d.id === chosen(kind)) ? chosen(kind) : '';
  sel.addEventListener('change', () => choose(kind, sel.value));
  return sel;
}

function slider(kind, max, get) {
  const value = el('span', { class: 'call-levels__value u-tabular' });
  const input = el('input', {
    class: 'call-levels__range', type: 'range', min: '0', max: String(max * 100), step: '5',
  });
  input.value = String(Math.round(get() * 100));
  trackFill(input);
  const show = () => { value.textContent = `${input.value}%`; };
  show();
  input.addEventListener('input', () => {
    show();
    setLevel(kind, Number(input.value) / 100);
  });
  return [input, value];
}

const line = (label, ...controls) => el('label', { class: 'call-levels__row' },
  el('span', { class: 'call-levels__label' }, label), ...controls);

const isNameless = (devs) => [...devs.mic, ...devs.camera, ...devs.speaker].length > 0
  && [...devs.mic, ...devs.camera, ...devs.speaker].every((d) => /^(Microphone|Camera|Speaker) \d+$/.test(d.label));

async function fill(box) {
  let devs = await listDevices();
  // Without a capture in this session — an incomplete nameless list: the
  // open panel opens the microphone for a moment itself (unlockNames).
  if (isNameless(devs) && !box.hidden && await unlockNames()) devs = await listDevices();
  const nameless = isNameless(devs);
  const rows = [
    line('Microphone', select('mic', devs)),
    line('Mic level', ...slider('mic', MIC_GAIN_MAX, micGain)),
    line('Speaker', select('speaker', devs)),
    line('Volume', ...slider('speaker', 1, outputVolume)),
    line('Camera', select('camera', devs)),
  ];
  if (nameless) {
    rows.push(el('button', {
      class: 'btn call-levels__allow', type: 'button',
      onclick: async () => {
        // Separately: there may be no camera or it may be busy — then a
        // combined request failed whole, and the microphone did not open either.
        for (const constraints of [{ audio: true }, { video: true }]) {
          try {
            const s = await navigator.mediaDevices.getUserMedia(constraints);
            for (const t of s.getTracks()) t.stop();
          } catch {
            // none or refused — what there is stays
          }
        }
        refreshAll();
      },
    }, 'Show device names'));
  }
  box.replaceChildren(...rows);
  // This panel's old sliders are replaced — their fill rules are not needed.
  pruneFills();
}

function refreshAll() {
  for (const box of panels) {
    if (box.isConnected) fill(box);
    else panels.delete(box);
  }
}

if (navigator.mediaDevices?.addEventListener) {
  navigator.mediaDevices.addEventListener('devicechange', refreshAll);
}

/**
 * The device and volume panel. hidden — hidden until it is opened (the
 * Devices button in the call window). The lists are re-read on every
 * showing: a headset plugged in is in the list already.
 */
export function devicePanel({ hidden = false } = {}) {
  const box = el('div', { class: 'call-levels', hidden });
  panels.add(box);
  fill(box);
  return box;
}

/** Show/hide the panel (re-reading the devices when shown). */
export function togglePanel(box) {
  box.hidden = !box.hidden;
  if (!box.hidden) fill(box);
}
