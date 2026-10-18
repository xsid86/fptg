import { el } from './core/dom.js';
import { icon, loadIcons } from './util/icons.js';
import { fillAvatar } from './util/avatar.js';

// The incoming call card (callcard.html) in a small window on top of all windows.
//
// The data — from the address (the main page puts it there, ui/call.js):
//   id — the call, name, video (1/0), avatar — the photo address, thumb — a
//   data URI of the blurred preview, uid — the other side's id (the
//   placeholder letter's colour).
// Presses go to the shell (chrome.webview.postMessage):
//   { t: 'call', action: 'accept' | 'decline' | 'open', id }
// The shell hides the window and passes this to the main page — it accepts
// and declines: the sound and video live there.

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
    // without the sprite the buttons stay with labels
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
