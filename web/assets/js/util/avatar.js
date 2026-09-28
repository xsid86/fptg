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
export function fillAvatar(box, chat) {
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
}
