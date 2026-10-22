import { on } from '../core/bus.js';
import { store } from '../core/store.js';
import { getPref } from './prefs.js';

// The page's sounds: a short chime for a new message and the ringtone of an
// incoming call. Synthesized with Web Audio — no audio files to ship or
// license, and the same in every shell.
//
// Who sounds when:
// - a message: not for the chat that is open while the window is in front
//   (as in Telegram); in the Android app not while it is in the background
//   either — there the system notification sounds, with the phone's own
//   sound, and the page would only double it;
// - a call: ui/call.js decides (ringFor); in the Android app in the
//   background the shell's call notification rings with the phone's
//   ringtone instead.
//
// Settings → Notifications and sounds turns either off (util/prefs.js:
// messageSound, callRingtone).

/** The Android app's page (fptg-android adds this to the user agent). */
export const onAndroid = () => navigator.userAgent.includes('fptg-android/');

const CHIME = [[880, 0, 0.12, 0.16], [1320, 0.09, 0.2, 0.13]];   // [Hz, start s, length s, peak]
// A rising and falling phrase, twice, then a pause — RING_PERIOD_MS in all.
const RING_NOTES = [659, 784, 988, 784];
const RING_STEP_S = 0.16;
const RING_NOTE_S = 0.22;
const RING_PEAK = 0.25;
const RING_PERIOD_MS = 3000;

let ctx = null;
let ringTimer = 0;
let ringing = false;

function audio() {
  if (!ctx) {
    try {
      ctx = new AudioContext();
    } catch {
      return null;
    }
  }
  // A browser starts the context suspended until the person touches the
  // page; resuming without a gesture is a harmless no-op.
  if (ctx.state === 'suspended') ctx.resume().catch(() => {});
  return ctx;
}

function tone(c, at, hz, length, peak) {
  const osc = c.createOscillator();
  const gain = c.createGain();
  osc.type = 'sine';
  osc.frequency.setValueAtTime(hz, at);
  gain.gain.setValueAtTime(0.0001, at);
  gain.gain.exponentialRampToValueAtTime(peak, at + 0.012);
  gain.gain.exponentialRampToValueAtTime(0.0001, at + length);
  osc.connect(gain).connect(c.destination);
  osc.start(at);
  osc.stop(at + length + 0.02);
}

export function playMessageSound() {
  if (!getPref('messageSound')) return;
  const c = audio();
  if (!c) return;
  const t = c.currentTime + 0.01;
  for (const [hz, start, length, peak] of CHIME) tone(c, t + start, hz, length, peak);
}

function ringPhrase() {
  if (!ringing) return;
  const c = audio();
  if (c) {
    const t = c.currentTime + 0.02;
    const phrase = RING_NOTES.length * RING_STEP_S;
    for (let rep = 0; rep < 2; rep++) {
      RING_NOTES.forEach((hz, k) => tone(c, t + rep * (phrase + 0.1) + k * RING_STEP_S, hz, RING_NOTE_S, RING_PEAK));
    }
  }
  ringTimer = setTimeout(ringPhrase, RING_PERIOD_MS);
}

/** Rings while `want` is true; call it again whenever that may change. */
export function ringFor(want) {
  const active = !!want && getPref('callRingtone') && !(onAndroid() && document.hidden);
  if (active === ringing) return;
  ringing = active;
  clearTimeout(ringTimer);
  if (active) ringPhrase();
}

/** The message chime for every arrival that should sound (see the top). */
export function mountSounds() {
  // Unlock the audio on the first touch or key, so the first sound is not lost.
  const unlock = () => {
    audio();
    window.removeEventListener('pointerdown', unlock, true);
    window.removeEventListener('keydown', unlock, true);
  };
  window.addEventListener('pointerdown', unlock, true);
  window.addEventListener('keydown', unlock, true);

  on('srv:arrival', (data) => {
    if (!data) return;
    if (onAndroid() && document.hidden) return;
    if (!document.hidden && document.hasFocus() && data.chatId === store.activeChatId) return;
    playMessageSound();
  });
}
