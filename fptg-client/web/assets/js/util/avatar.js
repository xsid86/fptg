import { el, clear } from '../core/dom.js';
import { initial } from './format.js';
import { holdImage } from './offscreen.js';

/**
 * A chat's picture, drawn into a box that already carries .avatar.
 *
 * Shared by the list row and the header above the history, because the
 * two are the same picture of the same chat and had no business
 * disagreeing about it - the header used to show the initial for every
 * chat, photo or not, simply because it was written separately.
 *
 * Three states, in the order the data arrives:
 *   * the real file, once it is on disk;
 *   * the inline thumbnail TDLib sends with the chat itself - a few
 *     hundred bytes, no download - blurred, because it is ~40px wide
 *     and reads as a broken image otherwise;
 *   * the initial on the chat's own accent colour, when there is no
 *     photo at all.
 *
 * The box is filled rather than built here: the header keeps one node
 * for the life of the page (see chat-header.js), and the list builds a
 * fresh one per row.
 */
// ------------------------------------------------- animated avatars
// An animated avatar (MPEG4 160x160, chat.avatarAnim) — a <video> over the
// picture, and ONLY while the avatar is in view: outside it the player is
// destroyed whole, together with the decoder (remove src and load() —
// otherwise the element does not give it up). A list of a hundred rows
// would otherwise have to hold a decoder for every animated one.
//
// One observer for all avatars — both in the list and in the header (the
// header is always on screen, so it plays all the time).

const animated = new Set();   // the .avatar elements with animation being watched
let watcher = null;

function startAnim(box) {
  if (box.querySelector('.avatar__video') || !box.dataset.anim) return;
  box.append(el('video', {
    class: 'avatar__img avatar__video', src: box.dataset.anim,
    autoplay: true, loop: true, muted: true, playsInline: true,
  }));
}

function stopAnim(box) {
  const video = box.querySelector('.avatar__video');
  if (!video) return;
  video.pause();
  video.removeAttribute('src');
  video.load();
  video.remove();
}

function observer() {
  if (!watcher) {
    // Without a margin: exactly "in view" or not.
    watcher = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting && entry.target.isConnected) startAnim(entry.target);
        else stopAnim(entry.target);
      }
    });
  }
  return watcher;
}

function forgetAnim(box) {
  stopAnim(box);
  if (animated.delete(box)) observer().unobserve(box);
  delete box.dataset.anim;
}

/**
 * Avatars that dropped out of the document: a video in a detached node
 * would keep decoding, so it is destroyed. But the observation is NOT: the
 * list caches rows (chat-list.js, rowNode) and with a filter returns the
 * same row back without a new fillAvatar; when it comes back into view, the
 * observer raises the video again itself.
 */
function sweepAnim() {
  for (const box of animated) {
    if (!box.isConnected) stopAnim(box);
  }
}

/** What is drawn now — so as not to redraw the same. */
const avatarKey = (chat) => [chat.avatar || '', chat.avatarThumb ? 't' : '',
  chat.avatarAnim || '', chat.deleted ? 'd' : '', chat.avatar || chat.avatarThumb ? '' : chat.title || ''].join('|');

export function fillAvatar(box, chat) {
  sweepAnim();
  // The chat list redraws rows on every change anywhere in it; without this
  // check an animated avatar would restart every time, and a picture be decoded.
  const key = avatarKey(chat);
  if (box.dataset.avatarKey === key) return;
  box.dataset.avatarKey = key;
  forgetAnim(box);

  box.classList.toggle('is-deleted', !!chat.deleted);
  clear(box);
  if (chat.avatar) {
    const img = el('img', { class: 'avatar__img', src: chat.avatar, alt: '' });
    // A hundred rows means a hundred decoded pictures, and seven of
    // them are on screen. Far-off rows fall back to the inline
    // thumbnail they already carry, which costs no download.
    holdImage(img, chat.avatar, chat.avatarThumb || '');
    box.append(img);
  } else if (chat.avatarThumb) {
    box.append(el('img', { class: 'avatar__img is-blur', src: chat.avatarThumb, alt: '' }));
  } else {
    box.textContent = chat.deleted ? '×' : initial(chat.title);
  }

  // The picture stays under the video: it is the frame before the video's
  // first frame, and what is seen when the avatar is off screen.
  if (chat.avatarAnim) {
    box.dataset.anim = chat.avatarAnim;
    // The list builds a row anew when its chat changes, and the previous
    // avatar of the same chat will not come back — it is forgotten
    // completely, otherwise the set and the observer would pile up such
    // nodes for hours.
    const owner = String(chat.id ?? '');
    if (owner) {
      for (const old of [...animated]) {
        if (old !== box && !old.isConnected && old.dataset.animOwner === owner) forgetAnim(old);
      }
    }
    box.dataset.animOwner = owner;
    animated.add(box);
    observer().observe(box);
  }
}
