import { el, clear, qs } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { fileSize } from '../util/format.js';
import { openEmojiPicker } from './picker.js';
import { uploadUrl } from '../core/session.js';
import { startUpload, endUpload, stopAction } from './sendaction.js';

// Sending files — as in the native Telegram client.
//
// Three entries: dragging onto the open chat, the paperclip in the composer
// and pasting from the clipboard. All three lead to one dialog: the file
// list, the caption, Add / Cancel / Send.
//
// Dragging shows zones. For pictures only there are two — "without
// compression" (as a file) and "quick send" (as a compressed photo), as in
// the native client; for everything else one — as a file. The chosen zone
// sets the dialog's mode, and in the dialog itself it can be switched while
// all the files are pictures.
//
// The bytes go to the server with POST /upload (one file at a time, with
// upload progress, the address and token — core/session.js), an id comes
// back; the message.sendFiles command hands those ids to the model. The
// path on disk is neither needed nor visible to the page.

// What Telegram accepts as a photo. GIF is left out on purpose: as a
// compressed photo it would become a still picture.
const PHOTO_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp', 'image/bmp']);
const isPhoto = (file) => PHOTO_TYPES.has(file.type);
const allPhotos = (files) => files.length > 0 && files.every(isPhoto);
// A video that goes as a video message in "media" mode (the server decides
// by the extension: mp4, mov, m4v, webm, mkv).
const VIDEO_TYPES = new Set(['video/mp4', 'video/quicktime', 'video/x-m4v', 'video/webm', 'video/x-matroska']);
const isMedia = (file) => isPhoto(file) || VIDEO_TYPES.has(file.type);
const allMedia = (files) => files.length > 0 && files.every(isMedia);

let hooks = {};
let layer = null;
let zone = null;
let picker = null;      // the hidden <input type=file> for the Add button

// The open dialog's state.
let files = [];
let asPhoto = false;
// The kind set by a paperclip menu item: 'document' or 'audio' — without
// the compression toggle; null — as before (compression for media).
let forced = null;
let previews = new Map();   // File -> the thumbnail's object URL, revoked on closing
let busy = false;
let xhr = null;
let cancelled = false;
let view = null;            // the dialog's nodes updated in place

// ------------------------------------------------------------ dropzone
let dragDepth = 0;

const hasFiles = (event) => [...(event.dataTransfer?.types ?? [])].includes('Files');

/**
 * Whether everything dragged is pictures. During dragging the files
 * themselves are unavailable, but the items already have a kind (MIME) —
 * that decides whether to show the second zone.
 */
function dragAllMedia(event) {
  const items = [...(event.dataTransfer?.items ?? [])];
  // Photos AND videos: a video is sent "quickly" too — as a video message,
  // not a file (the second zone used to be for pictures only).
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

  // A file dropped outside the zone (on the chat list, into the status bar)
  // must not open in the window instead of the app — the browser does
  // exactly that by default.
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

/** Redraws everything that depends on the file list; does not touch the caption. */
function refresh() {
  if (!view) return;
  // Compression is possible only while ALL the files are photos or videos,
  // and the kind is not set by a menu item.
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
  // The .w-* ladder is in 5% steps: the width is set by a class, not style.
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

/** A file to the server without a window (voice messages and round videos, ui/recorder.js): the upload id. */
export async function uploadFile(file) {
  const id = await upload(file, () => {});
  xhr = null;
  return id;
}

/** One file to the server; resolves to the upload id. */
async function upload(file, onProgress) {
  const url = await uploadUrl(file.name);
  return new Promise((resolve, reject) => {
    xhr = new XMLHttpRequest();
    xhr.open('POST', url);
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

/**
 * A file for a rich message (Rich mode in the input field): an upload
 * without a window. kind — the block kind (photo, video, gif, audio, file),
 * info — video info (as for message.sendFiles) or null. Uploads go one at a
 * time: upload holds one xhr per module.
 */
export async function uploadRichFile(file, mode) {
  let kind = 'file';
  if (mode === 'document') kind = 'file';
  else if (mode === 'audio') kind = 'audio';
  else if (file.type === 'image/gif') kind = 'gif';
  else if (isPhoto(file)) kind = 'photo';
  else if (isVideoFile(file)) kind = 'video';
  else if (/^audio\//.test(file.type)) kind = 'audio';
  let info = null;
  if (kind === 'video') {
    const probe = await videoInfo(file);
    if (probe) {
      info = { duration: probe.duration, w: probe.w, h: probe.h, tw: probe.tw, th: probe.th };
      if (probe.blob) {
        info.thumb = await upload(new File([probe.blob], 'thumb.jpg', { type: 'image/jpeg' }), () => {});
      }
    }
  }
  const id = await upload(file, () => {});
  xhr = null;
  return { id, kind, info };
}

// Video info for inputVideo: without it TDLib sets 320x320 and duration 0
// (a live log), and the preview comes out square, without a frame. The
// browser reads the metadata from the file itself; the frame — onto a
// canvas and into JPEG, uploaded as a separate file as the thumbnail.
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
      // A frame a little past the start: the first one is often black.
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
      // For a video message — the duration, size and a thumbnail frame.
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
      // "Sending a photo/video/file" to the other side while the bytes go to the server.
      startUpload(mode === 'media' ? (isPhoto(file) ? 'photo' : 'video') : 'document');
      ids.push(await upload(file, (loaded) => setProgress((done + loaded) / total)));
      done += file.size;
    }
    xhr = null;
    // From here TDLib itself uploads the file to Telegram — and sends the action too.
    endUpload();
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
    stopAction();
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
    // Already open — add to what is there.
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
    // As in the message field: Enter sends, Ctrl/Shift+Enter — a line break.
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

  // A click on the dimming around the window — like Cancel; Escape too, if
  // the emoji panel is not open (its Escape closes the panel itself).
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
  layer.addEventListener('dragover', (event) => {
    if (!view || busy || !hasFiles(event)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
  });
  layer.addEventListener('drop', (event) => {
    if (!view || busy || !hasFiles(event)) return;
    event.preventDefault();
    addFiles([...event.dataTransfer.files]);
  });

  // The paperclip and pasting from the clipboard: pictures compressed by
  // default, as in the native client.
  // mode — from the paperclip menu (ui/attachmenu.js): media | document | audio.
  on('ui:attach', ({ files: list, mode }) => {
    if (!hooks.canCompose()) return;
    // Rich mode: the file goes as a line into the text, between blocks
    // (ui/composer.js) — from the paperclip menu too, with its kind.
    if (hooks.richAttach?.(list, mode)) return;
    // The paperclip and pasting: photos and videos "compressed" by default
    // — a video goes as a video message, as in the native client; the
    // toggle in the window brings back sending as a file.
    openDialog(list, mode === 'media' || (!mode && allMedia(list)), mode ?? null);
  });
}
