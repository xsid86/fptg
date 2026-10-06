// Выбор устройств для звонков: микрофон, камера, динамик.
//
// Выбор — в localStorage ЭТОЙ страницы, не в настройках сервера: id
// устройств браузерные и на другой машине (морда отдельно от сервера —
// Android, Linux) значат другое или ничего. Хранилище может быть
// недоступно — тогда просто устройства по умолчанию.
//
// Названия устройств браузер отдаёт только после разрешения на
// микрофон/камеру, поэтому до первого звонка список может быть
// безымянным («Microphone 1»).

import { emit } from '../core/bus.js';
import { el } from '../core/dom.js';
import { trackFill, pruneFills } from '../util/rangefill.js';

const KEY = 'fptelegram.callDevices';

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
    // без хранилища выбор живёт до перезагрузки
  }
}

let prefs = read();

export const chosen = (kind) => prefs[kind] ?? '';

/** Выбрать устройство: kind — mic | camera | speaker, id '' — по умолчанию. */
export function choose(kind, id) {
  prefs = { ...prefs, [kind]: id };
  write(prefs);
  emit('calls:device', { kind, id });
  // Другие открытые панели (окно звонка, настройки) — показать новый выбор.
  refreshAll();
}

/** Ограничения getUserMedia для звука с выбранным микрофоном. */
export function micConstraints(extra = {}) {
  const id = chosen('mic');
  return { ...extra, ...(id ? { deviceId: { ideal: id } } : {}) };
}

/** Ограничения getUserMedia для видео с выбранной камерой. */
export function cameraConstraints(extra = {}) {
  const id = chosen('camera');
  return { ...extra, ...(id ? { deviceId: { ideal: id } } : {}) };
}

// ------------------------------------------------------- громкость
// Микрофон: 0..MIC_GAIN_MAX — усилитель WebAudio между микрофоном и
// звонком (openMic). Выход: 0..1 — громкость <audio> собеседника; выше
// 100% — только через WebAudio, а тогда выход не следует за выбранным
// динамиком (setSinkId есть у элемента), поэтому без усиления.
export const MIC_GAIN_MAX = 2;
const live = new Set();     // усилители открытых микрофонов

export const micGain = () => prefs.micGain ?? 1;
export const outputVolume = () => prefs.volume ?? 1;

/** kind: 'mic' (0..MIC_GAIN_MAX) или 'speaker' (0..1). */
export function setLevel(kind, value) {
  if (kind === 'mic') {
    prefs = { ...prefs, micGain: value };
    for (const g of live) g.gain.value = value;
  } else {
    prefs = { ...prefs, volume: value };
    // окна звонка переприменят громкость к своим <audio> (routeAudio)
    emit('calls:device', { kind: 'speaker' });
  }
  write(prefs);
}

/**
 * Микрофон через усилитель: MediaStream с одной дорожкой. stop() этой
 * дорожки гасит и настоящий микрофон, и усилитель — вызывающий код
 * останавливает её как обычную.
 */
export async function openMic(constraints) {
  const raw = await navigator.mediaDevices.getUserMedia({ audio: constraints, video: false });
  let ctx;
  try {
    ctx = new AudioContext();
  } catch {
    return raw;   // без WebAudio — микрофон как есть
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

/** Вывести звук элемента на выбранный динамик (если браузер умеет). */
export async function routeAudio(node) {
  const id = chosen('speaker');
  if (node) node.volume = Math.min(1, Math.max(0, outputVolume()));
  if (!node || typeof node.setSinkId !== 'function') return;
  try {
    await node.setSinkId(id);
  } catch {
    // устройство пропало — остаётся то, что было
  }
}

/** Устройства по видам: { mic: [{id, label}], camera: [...], speaker: [...] }. */
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

// ------------------------------------------------------------ панель
// Выбор устройств и громкость одной панелью: окно звонка, окно
// видеочата, настройки (раздел Calls). Открытых копий может быть
// несколько — выбор в одной сразу виден в остальных (refreshAll).
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

async function fill(box) {
  const devs = await listDevices();
  // Без разрешения на микрофон браузер не называет устройства.
  const nameless = [...devs.mic, ...devs.camera].length > 0
    && [...devs.mic, ...devs.camera].every((d) => /^(Microphone|Camera) \d+$/.test(d.label));
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
        try {
          const s = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
          for (const t of s.getTracks()) t.stop();
        } catch {
          // отказали — остаются безымянные
        }
        refreshAll();
      },
    }, 'Show device names'));
  }
  box.replaceChildren(...rows);
  // Старые ползунки этой панели заменены — их правила заливки не нужны.
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
 * Панель устройств и громкости. hidden — скрыта, пока её не откроют
 * (кнопка Devices в окне звонка). Списки перечитываются при каждом
 * показе: подключили гарнитуру — она уже в списке.
 */
export function devicePanel({ hidden = false } = {}) {
  const box = el('div', { class: 'call-levels', hidden });
  panels.add(box);
  fill(box);
  return box;
}

/** Показать/спрятать панель (перечитав устройства при показе). */
export function togglePanel(box) {
  box.hidden = !box.hidden;
  if (!box.hidden) fill(box);
}
