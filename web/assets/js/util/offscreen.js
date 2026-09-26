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

// img -> what it draws when near, and what it falls back to when not.
const held = new WeakMap();
// The observer holds a strong reference to everything it watches, so
// the set of watched nodes has to be swept by hand - otherwise every
// picture the history has ever built stays alive in it, which is the
// leak this module exists to prevent.
const watched = new Set();

let watcher = null;

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

function release(img, info) {
  if (info.off) return;
  info.off = true;
  if (info.thumb) {
    img.src = info.thumb;
    img.classList.add('is-placeholder');
  } else {
    // Nothing to stand in with: the box keeps its own background,
    // which is what an undownloaded one looks like anyway.
    img.removeAttribute('src');
  }
}

function restore(img, info) {
  if (!info.off) return;
  info.off = false;
  img.src = info.full;
  img.classList.remove('is-placeholder');
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
 * Forgets pictures whose node the history has thrown away.
 *
 * Hung on the same event that makes the history rebuild its nodes -
 * the same arrangement, and for the same reason, as the sticker
 * players in ui/sticker.js.
 */
function sweep() {
  for (const img of [...watched]) {
    if (img.isConnected) continue;
    watched.delete(img);
    held.delete(img);
    observer().unobserve(img);
  }
}
on('store:messages', sweep);
on('store:chats', sweep);
