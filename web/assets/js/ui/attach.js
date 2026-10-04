import { el, clear, qs } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { fileSize } from '../util/format.js';
import { openEmojiPicker } from './picker.js';

// Отправка файлов — как в нативном клиенте Telegram.
//
// Три входа: перетаскивание на открытый чат, скрепка в композере и
// вставка из буфера. Все три ведут в один диалог: список файлов, подпись,
// Add / Cancel / Send.
//
// Перетаскивание показывает зоны. Для одних картинок их две — «без
// сжатия» (файлом) и «быстрая отправка» (сжатым фото), как у нативного
// клиента; для всего остального одна — файлом. Выбранная зона задаёт
// режим диалога, а в самом диалоге его можно переключить, пока все
// файлы — картинки.
//
// Байты уходят на локальный сервер POST /upload (по одному файлу, с
// ходом загрузки), обратно приходит id; команда message.sendFiles
// отдаёт эти id модели. Путь на диске странице не нужен и не виден.

const UPLOAD_URL = '/upload';

// Что Telegram примет как фото. GIF сюда не входит намеренно: сжатым
// фото он стал бы неподвижной картинкой.
const PHOTO_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp', 'image/bmp']);
const isPhoto = (file) => PHOTO_TYPES.has(file.type);
const allPhotos = (files) => files.length > 0 && files.every(isPhoto);
// Видео, которое уйдёт видео-сообщением в режиме «медиа» (сервер решает
// по расширению: mp4, mov, m4v, webm, mkv).
const VIDEO_TYPES = new Set(['video/mp4', 'video/quicktime', 'video/x-m4v', 'video/webm', 'video/x-matroska']);
const isMedia = (file) => isPhoto(file) || VIDEO_TYPES.has(file.type);
const allMedia = (files) => files.length > 0 && files.every(isMedia);

let hooks = {};
let layer = null;
let zone = null;
let picker = null;      // скрытый <input type=file> для кнопки Add

// Состояние открытого диалога.
let files = [];
let asPhoto = false;
// Вид, заданный пунктом меню скрепки: 'document' или 'audio' — без
// переключателя сжатия; null — как раньше (сжатие для медиа).
let forced = null;
let previews = new Map();   // File -> object URL миниатюры, отзывается при закрытии
let busy = false;
let xhr = null;
let cancelled = false;
let view = null;            // узлы диалога, которые обновляются на месте

// ------------------------------------------------------------ dropzone
let dragDepth = 0;

const hasFiles = (event) => [...(event.dataTransfer?.types ?? [])].includes('Files');

/**
 * Картинки ли всё, что тащат. Во время перетаскивания сами файлы
 * недоступны, а вид (MIME) у элементов уже есть — по нему и решается,
 * показывать ли вторую зону.
 */
function dragAllMedia(event) {
  const items = [...(event.dataTransfer?.items ?? [])];
  // Фото И видео: видео тоже отправляется «быстро» — видео-сообщением,
  // а не файлом (раньше вторая зона была только для картинок).
  return items.length > 0 && items.every((item) => item.kind === 'file'
    && (PHOTO_TYPES.has(item.type) || VIDEO_TYPES.has(item.type)));
}

function drawZones(photos) {
  const make = (mode, title, note) => el('div', {
    class: `dropzone__zone dropzone__zone--${mode}`,
    dataset: { mode },
  },
  el('div', { class: 'dropzone__title' }, title),
  el('div', { class: 'dropzone__note' }, note));

  clear(zone);
  if (photos) {
    zone.append(
      make('file', 'Drop files here', 'to send them without compression'),
      make('photo', 'Drop photos and videos here', 'for quick sending'));
  } else {
    zone.append(make('file', 'Drop files here', 'to send them without compression'));
  }
}

function hideZones() {
  dragDepth = 0;
  zone.hidden = true;
  clear(zone);
}

function mountDropzone(area) {
  area.addEventListener('dragenter', (event) => {
    if (!hasFiles(event) || !hooks.canCompose() || busy) return;
    event.preventDefault();
    dragDepth += 1;
    if (dragDepth === 1) {
      drawZones(dragAllMedia(event));
      zone.hidden = false;
    }
  });
  area.addEventListener('dragover', (event) => {
    if (zone.hidden) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
    const over = event.target.closest?.('.dropzone__zone');
    for (const z of zone.children) z.classList.toggle('is-over', z === over);
  });
  area.addEventListener('dragleave', () => {
    if (zone.hidden) return;
    dragDepth -= 1;
    if (dragDepth <= 0) hideZones();
  });
  area.addEventListener('drop', (event) => {
    if (zone.hidden) return;
    event.preventDefault();
    const mode = event.target.closest?.('.dropzone__zone')?.dataset.mode ?? 'file';
    const dropped = [...event.dataTransfer.files];
    hideZones();
    if (dropped.length) openDialog(dropped, mode === 'photo' && allMedia(dropped));
  });

  // Файл, брошенный мимо зоны (на список чатов, в статусную строку), не
  // должен открываться в окне вместо приложения — браузер по умолчанию
  // делает именно это.
  window.addEventListener('dragover', (event) => {
    if (hasFiles(event)) event.preventDefault();
  });
  window.addEventListener('drop', (event) => {
    if (hasFiles(event)) event.preventDefault();
  });
}

// -------------------------------------------------------------- dialog
function titleText() {
  const n = files.length;
  if (forced === 'audio') return n === 1 ? 'Send a song' : `Send ${n} songs`;
  if (asPhoto) return n === 1 ? 'Send a photo or video' : `Send ${n} photos and videos`;
  return n === 1 ? 'Send as a file' : `Send ${n} files`;
}

function previewOf(file) {
  if (!isPhoto(file)) return null;
  let url = previews.get(file);
  if (!url) {
    url = URL.createObjectURL(file);
    previews.set(file, url);
  }
  return url;
}

function fileRow(file) {
  const url = previewOf(file);
  return el('li', { class: 'attach__item' },
    url
      ? el('img', { class: 'attach__thumb', src: url, alt: '' })
      : el('span', { class: 'attach__thumb attach__thumb--file' }, icon('file')),
    el('div', { class: 'attach__meta' },
      el('div', { class: 'attach__name', title: file.name }, file.name),
      el('div', { class: 'attach__size u-tabular' }, fileSize(file.size))),
    el('button', {
      class: 'btn btn--icon attach__remove',
      type: 'button',
      title: 'Remove',
      disabled: busy,
      onclick: () => removeFile(file),
    }, icon('close', 'icon--sm'), el('span', { class: 'u-sr-only' }, 'Remove')));
}

/** Перерисовывает всё, что зависит от списка файлов; подпись не трогает. */
function refresh() {
  if (!view) return;
  // Сжатие возможно, только пока ВСЕ файлы — фото или видео, и вид не
  // задан пунктом меню.
  if (!allMedia(files) || forced) asPhoto = false;
  view.title.textContent = titleText();
  clear(view.list).append(...files.map(fileRow));
  view.compressRow.hidden = !allMedia(files) || !!forced;
  view.compress.checked = asPhoto;
}

function removeFile(file) {
  if (busy) return;
  files = files.filter((f) => f !== file);
  const url = previews.get(file);
  if (url) URL.revokeObjectURL(url);
  previews.delete(file);
  if (!files.length) {
    closeDialog();
    return;
  }
  refresh();
}

function addFiles(more) {
  if (busy || !more.length) return;
  files = files.concat(more);
  refresh();
}

function insertIntoCaption(text) {
  const box = view.caption;
  const start = box.selectionStart;
  const end = box.selectionEnd;
  box.value = box.value.slice(0, start) + text + box.value.slice(end);
  const caret = start + text.length;
  box.setSelectionRange(caret, caret);
  box.focus();
}

function pickEmoji() {
  openEmojiPicker(view.emoji, (answer) => {
    if (!view) return;
    if (typeof answer === 'string') {
      insertIntoCaption(answer);
    } else if (answer?.customEmojiId) {
      const markup = hooks.customEmojiMarkup(answer.customEmojiId, answer.emoji);
      if (markup) insertIntoCaption(markup);
    }
  });
}

function setProgress(fraction) {
  const pct = Math.max(0, Math.min(100, Math.round(fraction * 100)));
  // Лестница .w-* — шаг 5%: ширину задаёт класс, а не style.
  view.bar.className = `attach__bar-fill w-${Math.round(pct / 5) * 5}`;
  view.percent.textContent = `${pct}%`;
}

function setBusy(on) {
  busy = on;
  view.progress.hidden = !on;
  view.send.disabled = on;
  view.add.disabled = on;
  view.compress.disabled = on;
  view.caption.disabled = on;
  view.emoji.disabled = on;
  for (const btn of view.list.querySelectorAll('.attach__remove')) btn.disabled = on;
}

/** Один файл на сервер; resolve — id загрузки. */
function upload(file, onProgress) {
  return new Promise((resolve, reject) => {
    xhr = new XMLHttpRequest();
    xhr.open('POST', `${UPLOAD_URL}?name=${encodeURIComponent(file.name)}`);
    xhr.upload.addEventListener('progress', (event) => onProgress(event.loaded));
    xhr.addEventListener('load', () => {
      const answer = xhr.responseText.trim();
      if (xhr.status === 200 && answer) resolve(answer);
      else reject(new Error(answer || `Upload failed (${xhr.status})`));
    });
    xhr.addEventListener('error', () => reject(new Error('Upload failed')));
    xhr.addEventListener('abort', () => reject(new Error('cancelled')));
    xhr.send(file);
  });
}

// Сведения о видео для inputVideo: без них TDLib ставит 320x320 и
// длительность 0 (живой лог), и превью выходит квадратным, без кадра.
// Браузер сам читает метаданные из файла; кадр — на холст и в JPEG, его
// грузим отдельным файлом как миниатюру.
const THUMB_MAX = 320;
const VIDEO_PROBE_MS = 8000;

function videoInfo(file) {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement('video');
    let settled = false;
    const done = (info) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      video.removeAttribute('src');
      video.load();
      URL.revokeObjectURL(url);
      resolve(info);
    };
    const timer = setTimeout(() => done(null), VIDEO_PROBE_MS);
    video.muted = true;
    video.preload = 'auto';
    video.addEventListener('loadedmetadata', () => {
      // Кадр чуть дальше начала: первый часто чёрный.
      video.currentTime = Math.min(0.5, (video.duration || 1) / 2);
    }, { once: true });
    video.addEventListener('seeked', () => {
      const w = video.videoWidth;
      const h = video.videoHeight;
      if (!w || !h) {
        done(null);
        return;
      }
      const scale = Math.min(1, THUMB_MAX / Math.max(w, h));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(w * scale));
      canvas.height = Math.max(1, Math.round(h * scale));
      canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
      canvas.toBlob((blob) => done({
        duration: Math.round(video.duration) || 0, w, h,
        blob, tw: canvas.width, th: canvas.height,
      }), 'image/jpeg', 0.8);
    }, { once: true });
    video.addEventListener('error', () => done(null), { once: true });
    video.src = url;
  });
}

const isVideoFile = (file) => VIDEO_TYPES.has(file.type)
  || /\.(mp4|mov|m4v|webm|mkv)$/i.test(file.name);

async function send() {
  if (busy || !files.length) return;
  cancelled = false;
  view.error.textContent = '';
  setBusy(true);
  setProgress(0);

  const total = files.reduce((sum, f) => sum + f.size, 0) || 1;
  let done = 0;
  const ids = [];
  const meta = [];
  const mode = forced ?? (asPhoto ? 'media' : 'document');
  try {
    for (const file of files) {
      // Видео-сообщению — длительность, размеры и кадр-миниатюра.
      let info = null;
      if (mode === 'media' && isVideoFile(file)) {
        const probe = await videoInfo(file);
        if (probe) {
          info = { duration: probe.duration, w: probe.w, h: probe.h, tw: probe.tw, th: probe.th };
          if (probe.blob) {
            info.thumb = await upload(new File([probe.blob], 'thumb.jpg', { type: 'image/jpeg' }),
              () => {});
          }
        }
      }
      meta.push(info);
      ids.push(await upload(file, (loaded) => setProgress((done + loaded) / total)));
      done += file.size;
    }
    xhr = null;
    await hooks.call('message.sendFiles', {
      files: ids,
      meta,
      mode,
      caption: view.caption.value,
      html: hooks.htmlMode(),
      silent: hooks.isSilent(),
      replyTo: hooks.takeReply(),
    });
    closeDialog();
  } catch (error) {
    xhr = null;
    if (cancelled) return;
    setBusy(false);
    view.error.textContent = error instanceof Error ? error.message : String(error);
  }
}

function cancel() {
  if (busy) {
    cancelled = true;
    xhr?.abort();
  }
  closeDialog();
}

function closeDialog() {
  for (const url of previews.values()) URL.revokeObjectURL(url);
  previews = new Map();
  files = [];
  busy = false;
  view = null;
  layer.hidden = true;
  clear(layer);
}

function openDialog(list, photos, mode = null) {
  if (!list.length) return;
  if (view) {
    // Уже открыт — добавить к тому, что есть.
    addFiles(list);
    return;
  }
  files = [...list];
  forced = mode === 'document' || mode === 'audio' ? mode : null;
  asPhoto = !forced && photos && allMedia(files);

  const compress = el('input', {
    class: 'switch__input', type: 'checkbox', id: 'attach-compress',
    onchange: () => {
      asPhoto = compress.checked && allMedia(files);
      view.title.textContent = titleText();
    },
  });
  const caption = el('textarea', {
    class: 'attach__caption-input', rows: 1, placeholder: 'Caption',
  });
  caption.addEventListener('keydown', (event) => {
    // Как в поле сообщения: Enter отправляет, Ctrl/Shift+Enter — перенос.
    if (event.key !== 'Enter' || event.ctrlKey || event.shiftKey) return;
    event.preventDefault();
    send();
  });

  view = {
    title: el('h2', { class: 'attach__title' }),
    list: el('ul', { class: 'attach__list' }),
    compress,
    compressRow: el('label', { class: 'attach__compress', htmlFor: 'attach-compress' },
      el('span', {}, 'Send as photo or video'),
      el('span', { class: 'switch' }, compress, el('span', { class: 'switch__track' }))),
    caption,
    emoji: el('button', {
      class: 'btn btn--icon attach__emoji', type: 'button', title: 'Emoji',
      onclick: pickEmoji,
    }, icon('smile'), el('span', { class: 'u-sr-only' }, 'Emoji')),
    progress: el('div', { class: 'attach__progress', hidden: true }),
    bar: el('span', { class: 'attach__bar-fill w-0' }),
    percent: el('span', { class: 'attach__percent u-tabular' }, '0%'),
    error: el('p', { class: 'attach__error', role: 'alert' }),
    add: el('button', {
      class: 'btn attach__add', type: 'button', onclick: () => picker.click(),
    }, 'Add'),
    send: el('button', {
      class: 'btn btn--primary attach__send', type: 'button', onclick: send,
    }, 'Send'),
  };
  view.progress.append(el('span', { class: 'attach__bar' }, view.bar), view.percent);

  layer.append(el('div', { class: 'attach', role: 'dialog', 'aria-modal': 'true',
    'aria-label': 'Send files' },
  view.title,
  view.list,
  view.compressRow,
  el('div', { class: 'attach__caption' }, view.caption, view.emoji),
  view.progress,
  view.error,
  el('div', { class: 'attach__buttons' },
    view.add,
    el('span', { class: 'attach__spacer' }),
    el('button', { class: 'btn attach__cancel', type: 'button', onclick: cancel }, 'Cancel'),
    view.send)));

  refresh();
  layer.hidden = false;
  caption.focus();
}

// --------------------------------------------------------------- mount
/**
 * hooks: { call(cmd, args), canCompose(), htmlMode(), isSilent(),
 *          takeReply(), customEmojiMarkup(id, emoji) }
 */
export function mountAttach(layerNode, zoneNode, dropArea, options) {
  layer = layerNode;
  zone = zoneNode;
  hooks = options;

  picker = el('input', { type: 'file', multiple: true, hidden: true });
  picker.addEventListener('change', () => {
    const more = [...picker.files];
    picker.value = '';
    addFiles(more);
  });
  document.body.append(picker);

  // Клик по затемнению вокруг окна — как Cancel; Escape — тоже, если
  // панель эмодзи не открыта (её Escape закрывает её саму).
  layer.addEventListener('click', (event) => {
    if (event.target === layer) cancel();
  });
  layer.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      cancel();
    }
  });

  mountDropzone(dropArea);

  // Скрепка и вставка из буфера: картинки по умолчанию сжатыми, как у
  // нативного клиента.
  // mode — от меню скрепки (ui/attachmenu.js): media | document | audio.
  on('ui:attach', ({ files: list, mode }) => {
    if (!hooks.canCompose()) return;
    // Скрепка и вставка: фото и видео по умолчанию «сжатыми» — видео
    // уходит видео-сообщением, как у нативного клиента; переключатель в
    // окне возвращает отправку файлом.
    openDialog(list, mode === 'media' || (!mode && allMedia(list)), mode ?? null);
  });
}
