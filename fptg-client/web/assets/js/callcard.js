import { el } from './core/dom.js';
import { icon, loadIcons } from './util/icons.js';
import { fillAvatar } from './util/avatar.js';

// Карточка входящего звонка (callcard.html) в окошке поверх всех окон.
//
// Данные — из адреса (их кладёт главная страница, ui/call.js):
//   id — звонок, name, video (1/0), avatar — адрес фото, thumb — data-URI
//   размытого превью, uid — id собеседника (цвет буквы-заглушки).
// Нажатия уходят оболочке (chrome.webview.postMessage):
//   { t: 'call', action: 'accept' | 'decline' | 'open', id }
// Оболочка прячет окошко и передаёт это главной странице — принимает и
// отклоняет она: звук и видео живут там.

const q = new URLSearchParams(location.search);
const id = Number(q.get('id')) || 0;
const video = q.get('video') === '1';

function send(action) {
  const msg = { t: 'call', action, id };
  if (window.chrome?.webview) window.chrome.webview.postMessage(JSON.stringify(msg));
}

const button = (cls, iconName, label, action) => el('button', {
  class: `callcard__btn ${cls}`, type: 'button', title: label,
  onclick: (event) => {
    event.stopPropagation();
    send(action);
  },
}, el('span', { class: 'callcard__circle' }, icon(iconName)),
el('span', { class: 'callcard__label', textContent: label }));

async function main() {
  try {
    await loadIcons();
  } catch {
    // без спрайта кнопки останутся с подписями
  }
  const avatar = el('span', { class: 'avatar callcard__avatar' });
  fillAvatar(avatar, {
    id: Number(q.get('uid')) || id, title: q.get('name') || '',
    avatar: q.get('avatar') || '', avatarThumb: q.get('thumb') || '',
  });
  const card = el('div', {
    class: 'callcard', role: 'button', title: 'Open the app',
    onclick: () => send('open'),
  },
  el('div', { class: 'callcard__head' },
    avatar,
    el('div', { class: 'callcard__who' },
      el('div', { class: 'callcard__name', textContent: q.get('name') || 'Unknown' }),
      el('div', { class: 'callcard__what', textContent: video ? 'Incoming video call' : 'Incoming call' }))),
  el('div', { class: 'callcard__actions' },
    button('callcard__btn--accept', video ? 'video' : 'phone', 'Accept', 'accept'),
    button('callcard__btn--decline', 'phone-down', 'Decline', 'decline')));
  document.body.append(card);
}

main();
