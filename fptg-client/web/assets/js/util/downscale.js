// Photo previews shrunk by the page itself, with a proper filter.
//
// A preview is the 800px photoSize shown in a box of 150-420px: the browser
// draws it scaled down three to four times, and its own filter at that
// ratio leaves text and edges jagged (measured: 369x800 in a 218x313 album
// cell; image-rendering changes nothing). createImageBitmap with
// resizeQuality 'high' does what Telegram Desktop does - resamples once to
// the box's device pixels - and the <img> shows that instead.
//
// Cached by file and size, so a picture released off screen and brought
// back (util/offscreen.js) costs no second resampling.

// Less than this, the browser's own scaling is fine.
const MIN_RATIO = 1.5;
// Resampled previews kept: a few tens of KB each.
const CACHE_CAP = 200;
const JPEG_QUALITY = 0.92;

// `${src}|${w}x${h}` -> Promise of a blob URL ('' when it failed).
const cache = new Map();

function remember(key, job) {
  cache.set(key, job);
  if (cache.size <= CACHE_CAP) return;
  const [oldKey, old] = cache.entries().next().value;
  cache.delete(oldKey);
  old.then((url) => { if (url) URL.revokeObjectURL(url); });
}

async function resample(img, w, h) {
  const bitmap = await createImageBitmap(img, {
    resizeWidth: w, resizeHeight: h, resizeQuality: 'high',
  });
  const canvas = new OffscreenCanvas(w, h);
  canvas.getContext('2d').drawImage(bitmap, 0, 0);
  bitmap.close();
  const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: JPEG_QUALITY });
  return URL.createObjectURL(blob);
}

function shrink(img) {
  const src = img.src;
  if (!src || /^(blob|data):/.test(src) || img.classList.contains('is-placeholder')) return;
  // The box in device pixels; the bounding box includes the interface scale.
  const rect = img.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const nw = img.naturalWidth;
  const nh = img.naturalHeight;
  if (!rect.width || !rect.height || !nw || !nh) return;
  // object-fit: cover - the picture fills the box on both sides.
  const scale = Math.max((rect.width * dpr) / nw, (rect.height * dpr) / nh);
  if (scale * MIN_RATIO > 1) return;
  const w = Math.max(1, Math.round(nw * scale));
  const h = Math.max(1, Math.round(nh * scale));
  const key = `${src}|${w}x${h}`;
  let job = cache.get(key);
  if (job) {
    // The youngest at the end: eviction starts from the oldest.
    cache.delete(key);
    cache.set(key, job);
  } else {
    job = resample(img, w, h).catch(() => '');
    remember(key, job);
  }
  job.then((url) => {
    // Only if it still shows the same file (not released meanwhile).
    if (url && img.src === src) img.src = url;
  });
}

/** Every time the <img> loads its file, it is resampled to its box. */
export function smoothDownscale(img) {
  img.addEventListener('load', () => shrink(img));
}
