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
// Анимированная аватарка (MPEG4 160x160, chat.avatarAnim) — <video>
// поверх картинки, и ТОЛЬКО пока аватарка в зоне видимости: за её
// пределами плеер уничтожается целиком, вместе с декодером (снять src и
// load() — иначе элемент его не отдаёт). Списку в сотню строк иначе
// пришлось бы держать по декодеру на каждую анимированную.
//
// Один наблюдатель на все аватарки — и в списке, и в шапке (шапка всегда
// на экране, значит, играет постоянно).

const animated = new Set();   // .avatar с анимацией, за которыми следим
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
    // Без запаса: ровно «в кадре» или нет.
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
 * Аватарки, выпавшие из документа: видео в отцепленном узле продолжало
 * бы декодировать, поэтому оно уничтожается. А наблюдение — НЕТ: список
 * кэширует строки (chat-list.js, rowNode) и при фильтре возвращает ту же
 * строку обратно без нового fillAvatar; вернётся в кадр — наблюдатель
 * сам поднимет видео снова.
 */
function sweepAnim() {
  for (const box of animated) {
    if (!box.isConnected) stopAnim(box);
  }
}

/** Что сейчас нарисовано — чтобы не перерисовывать то же самое. */
const avatarKey = (chat) => [chat.avatar || '', chat.avatarThumb ? 't' : '',
  chat.avatarAnim || '', chat.deleted ? 'd' : '', chat.avatar || chat.avatarThumb ? '' : chat.title || ''].join('|');

export function fillAvatar(box, chat) {
  sweepAnim();
  // Список чатов перерисовывает строки на каждое изменение где угодно в
  // нём; без этой проверки анимированная аватарка начиналась бы заново
  // каждый раз, а картинка — декодировалась.
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

  // Картинка остаётся под видео: она и есть кадр до первого кадра
  // видео, и то, что видно, когда аватарка вне экрана.
  if (chat.avatarAnim) {
    box.dataset.anim = chat.avatarAnim;
    // Список строит строку заново, когда меняется её чат, и прежняя
    // аватарка того же чата больше не вернётся — её забываем совсем,
    // иначе набор и наблюдатель копили бы такие узлы часами.
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
