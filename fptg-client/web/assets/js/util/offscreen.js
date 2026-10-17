import { on } from '../core/bus.js';

// Letting go of pictures that are nowhere near the screen.
//
// An <img> keeps a DECODED bitmap for as long as it is in the
// document, and the history never removes anything: measured on a
// news channel, paging back twelve times left 600 messages in the DOM
// and 78 loaded pictures holding 83 MB of pixels - with most of that
// history's media not even fetched yet. That is the bulk of what the
// WebView2 renderer was carrying.
//
// So the picture is released once it is far enough away and put back
// when it comes near. Released means: the small blurred stamp that
// rode inside the message takes its place, which is the same thing
// shown before the file arrived. The file itself is already on disk
// and the URL is local, so coming back costs a decode, not a download.
//
// THIS IS ONLY SAFE BECAUSE THE BOX KNOWS ITS SIZE. A media box is
// sized from the w/h TDLib puts in the message (see sizedBox in
// ui/message.js), so swapping the picture out changes no layout and
// moves nothing under the reader. Doing this before that fix would
// have made the history jump on every scroll.

// How far outside the viewport a picture is still worth keeping. Two
// screenfuls or so: enough that a flick of the wheel never shows an
// empty box, small enough that a long history holds a handful of
// bitmaps instead of hundreds.
const REACH = '1200px';

// HOW MANY PICTURES MAY HOLD THEIR FILE AT ONCE.
//
// The reach above is a distance, not a quantity, and a dense run of
// small pictures - a wall of stickers, a list of a hundred avatars -
// can put a great many of them within it. The browser's own decoded
// image cache is sized against the machine, not against us: measured
// at 128 MB on a long session. This is the ceiling we can actually
// impose.
//
// Generous against what a screen can show (a handful) and mean against
// what a scroll can accumulate. Nothing on screen is ever evicted, so
// the cap gives way rather than blanking something the reader is
// looking at.
const HOLD_CAP = 48;

// node -> what it draws when near, and what it falls back to when not.
const held = new WeakMap();
// The ones holding their file right now, least recently restored
// first - a Map keeps insertion order, which is the whole trick.
const restored = new Map();
// The observer holds a strong reference to everything it watches, so
// the set of watched nodes has to be swept by hand - otherwise every
// picture the history has ever built stays alive in it, which is the
// leak this module exists to prevent.
const watched = new Set();

let watcher = null;
let viewWatcher = null;

function observer() {
  if (!watcher) {
    watcher = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const info = held.get(entry.target);
        if (!info) continue;
        info.near = entry.isIntersecting;
        if (entry.isIntersecting) restore(entry.target, info);
        else release(entry.target, info);
      }
    }, { rootMargin: REACH });
  }
  return watcher;
}

/**
 * Plays a loop only while it is ON SCREEN, which is a different
 * question from whether its file is worth holding - hence a second
 * observer with no margin at all. A GIF two screens away is still
 * cheap to keep loaded and must not be running: the compositor wakes
 * the window for every frame of it either way.
 */
function viewObserver() {
  if (!viewWatcher) {
    viewWatcher = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const info = held.get(entry.target);
        if (!info) continue;
        // What may not be thrown out to keep under the cap.
        info.visible = entry.isIntersecting;
        // Leaving the screen is the moment a node BECOMES evictable,
        // and the cap is otherwise only ever tested when something new
        // is taken on. After a burst - a page of history arriving all
        // at once - that could leave the set over the cap until the
        // next arrival.
        if (!entry.isIntersecting) prune();
        if (!info.video || !info.loop) continue;
        if (entry.isIntersecting && !info.off) {
          // A sticker is SHOWN once per appearance; a GIF runs for as
          // long as it is looked at.
          if (info.loop === 'once') entry.target.currentTime = 0;
          entry.target.play().catch(() => { /* went away mid-start */ });
        } else {
          entry.target.pause();
          if (info.loop === 'once') entry.target.currentTime = 0;
        }
      }
    }, { rootMargin: '0px' });
  }
  return viewWatcher;
}

function release(node, info) {
  if (info.off) return;
  info.off = true;
  restored.delete(node);
  if (info.video) return releaseVideo(node, info);
  const img = node;
  if (info.thumb) {
    img.src = info.thumb;
    img.classList.add('is-placeholder');
  } else {
    // Nothing to stand in with: the box keeps its own background,
    // which is what an undownloaded one looks like anyway.
    img.removeAttribute('src');
  }
}

function restore(node, info) {
  if (!info.off) return;
  info.off = false;
  // Youngest at the end, which is where the eviction below starts
  // counting from.
  restored.delete(node);
  restored.set(node, info);
  prune();
  if (info.video) return restoreVideo(node, info);
  node.src = info.full;
  node.classList.remove('is-placeholder');
}

/**
 * Brings the number holding a file back under the cap, oldest first
 * and never one that is on screen.
 *
 * If everything held is on screen the cap simply gives: a ceiling is
 * worth having, but not at the price of a blank where the reader is
 * looking.
 */
function prune() {
  if (restored.size <= HOLD_CAP) return;
  for (const [node, info] of restored) {
    if (restored.size <= HOLD_CAP) return;
    // Only what is KNOWN to be off screen. A node observed a moment
    // ago has not been reported on yet, and evicting it would blank
    // something the reader may well be looking at.
    if (info.visible !== false) continue;
    release(node, info);
  }
}

// A <video> costs more than a picture and more of them are running:
// a Telegram "GIF" and a webm sticker are autoplaying loops, so off
// the screen they go on decoding frames nobody is looking at. Dropping
// the source is what frees the decoder and its buffers - removing the
// attribute alone does not, load() is what makes the element let go.
function releaseVideo(video, info) {
  info.at = video.currentTime;
  video.pause();
  video.removeAttribute('src');
  video.load();
}

function restoreVideo(video, info) {
  video.src = info.full;
  // Where the reader had got to. Only meaningful for the one kind that
  // has controls; a loop starts wherever it likes.
  if (info.at) {
    video.addEventListener('loadedmetadata', () => {
      try { video.currentTime = info.at; } catch { /* past the end */ }
    }, { once: true });
  }
  // Started here only if the view observer has ALREADY said "on screen":
  // coming back within reach is still not the same as coming into view.
  // Уже на экране — играть сразу. Порядок двух наблюдателей НЕ
  // гарантирован, а внутри прокручиваемой истории запас REACH не
  // действует (он расширяет только окно, не рамку прокрутки), так что
  // оба срабатывают в одном кадре. Замерено живьём: «на экране» пришло
  // РАНЬШЕ «рядом» — play() пропускался из-за ещё снятого источника, а
  // вернувший его restore запустить не пытался; гифка стояла постером до
  // клика (чаще всего в ветке комментариев).
  if (info.loop && info.visible) {
    if (info.loop === 'once') video.currentTime = 0;
    video.play().catch(() => { /* went away mid-start */ });
  }
}

/**
 * Watches one picture: `full` is the real file, `thumb` the blurred
 * stamp to wear while it is away (may be empty).
 *
 * Called at build time, by whoever creates the <img>. Only for images
 * that HAVE their file - one still waiting for its download is already
 * showing the stamp and has nothing to release.
 */
export function holdImage(img, full, thumb = '') {
  if (!img || !full) return;
  const info = { full, thumb, off: false };
  held.set(img, info);
  // It is built HOLDING its file, so it counts against the cap from
  // this moment - not only if it is released and comes back. Without
  // this the ceiling only ever saw the returners: measured, 94 held
  // pictures against a cap of 48.
  restored.set(img, info);
  prune();
  watched.add(img);
  observer().observe(img);
  // Not for playing anything - for knowing what is on screen, which is
  // what the cap must never evict.
  viewObserver().observe(img);
}

/**
 * The same for a <video>: `full` is the file, and `loop` says how it
 * runs - 'loop' for a GIF, which plays while it is looked at, 'once'
 * for a sticker, which plays a single time per appearance. Anything
 * else (a video with controls) is the reader's to start.
 *
 * Safe for the same reason the pictures are: the box is sized from
 * what TDLib said about the file, so an emptied player leaves the
 * layout exactly where it was. A poster, where there is one, keeps
 * standing in by itself - it is an attribute, not the source.
 */
export function holdVideo(video, full, loop = false) {
  if (!video || !full) return;
  const info = { full, video: true, loop, at: 0, off: false };
  held.set(video, info);
  restored.set(video, info);
  prune();
  watched.add(video);
  observer().observe(video);
  viewObserver().observe(video);
}

/**
 * Сменить, как играет уже взятое видео (настройки Battery and animation,
 * Chat settings — без перерисовки истории): 'loop', 'once' или false —
 * только по щелчку.
 */
export function setVideoMode(video, loop) {
  const info = held.get(video);
  if (!info) return;
  info.loop = loop;
  video.loop = loop === 'loop';
  if (!loop) {
    video.pause();
  } else if (info.visible && !info.off) {
    video.play().catch(() => { /* went away mid-start */ });
  }
}

/**
 * Отпускает всё, что держится внутри `root`, СЕЙЧАС, а не по
 * следующему событию истории.
 *
 * Для тех, кто выбрасывает узлы сам и знает когда — панель эмодзи и
 * стикеров при смене набора или закрытии. sweep() ниже ловит только
 * отцепленные узлы и только по store:messages/store:chats; панель ни
 * одного из этих событий не вызывает, и её видео до тех пор продолжали
 * держать декодер. Видео отпускается так же, как при уходе за экран:
 * без load() элемент источник не отдаёт.
 */
export function forget(root) {
  if (!root) return;
  for (const node of [...watched]) {
    if (node !== root && !root.contains(node)) continue;
    const info = held.get(node);
    if (info?.video) releaseVideo(node, info);
    else node.removeAttribute('src');
    watched.delete(node);
    held.delete(node);
    restored.delete(node);
    observer().unobserve(node);
    viewObserver().unobserve(node);
  }
}

/**
 * Forgets pictures whose node the history has thrown away.
 *
 * Hung on the same event that makes the history rebuild its nodes -
 * the same arrangement, and for the same reason, as the sticker
 * players in ui/sticker.js.
 */
function sweep() {
  for (const node of [...watched]) {
    if (node.isConnected) continue;
    watched.delete(node);
    held.delete(node);
    restored.delete(node);
    observer().unobserve(node);
    viewObserver().unobserve(node);
  }
}
on('store:messages', sweep);
on('store:chats', sweep);
