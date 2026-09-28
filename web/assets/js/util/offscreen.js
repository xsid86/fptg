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

// node -> what it draws when near, and what it falls back to when not.
const held = new WeakMap();
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
        if (!info?.video || !info.loop) continue;
        if (entry.isIntersecting && !info.off) {
          entry.target.play().catch(() => { /* went away mid-start */ });
        } else {
          entry.target.pause();
        }
      }
    }, { rootMargin: '0px' });
  }
  return viewWatcher;
}

function release(node, info) {
  if (info.off) return;
  info.off = true;
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
  if (info.video) return restoreVideo(node, info);
  node.src = info.full;
  node.classList.remove('is-placeholder');
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
  // NOT started here. Coming back within reach is not the same as
  // coming into view, and only the view observer above decides that.
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
  held.set(img, { full, thumb, off: false });
  watched.add(img);
  observer().observe(img);
}

/**
 * The same for a <video>: `full` is the file, `loop` says whether it
 * plays by itself (a GIF or a webm sticker) and so has to be started
 * again on the way back.
 *
 * Safe for the same reason the pictures are: the box is sized from
 * what TDLib said about the file, so an emptied player leaves the
 * layout exactly where it was. A poster, where there is one, keeps
 * standing in by itself - it is an attribute, not the source.
 */
export function holdVideo(video, full, loop = false) {
  if (!video || !full) return;
  held.set(video, { full, video: true, loop, at: 0, off: false });
  watched.add(video);
  observer().observe(video);
  if (loop) viewObserver().observe(video);
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
    observer().unobserve(node);
    viewObserver().unobserve(node);
  }
}
on('store:messages', sweep);
on('store:chats', sweep);
