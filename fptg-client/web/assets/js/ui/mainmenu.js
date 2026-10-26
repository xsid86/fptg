import { el, clear } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { APP_VERSION } from '../version.js';

// The app's menu (2026-10-26), as in Telegram Desktop: a button at the left
// of the list's header opens a panel sliding in from the left — the account
// on top, then My profile, New group, New channel, Contacts, Saved
// messages and Settings. On a phone it takes the whole width and has a
// close button (blocks/_main-menu.scss). It replaced the Chats /
// Archive / Contacts tabs: the archive is now the first row of the list
// (ui/chat-list.js), and contacts are reached from here.
//
// What each item does belongs to main.js (hooks), the menu only lays them out.

const CLOSE_MS = 250;            // the slide out (blocks/_main-menu.scss), then hidden

let hooks = {};
let root = null;
let panel = null;
let closeTimer = 0;

export function mountMainMenu(head, options) {
  hooks = options ?? {};
  const button = el('button', {
    class: 'sidebar__menu', type: 'button', title: 'Menu',
    'aria-haspopup': 'dialog',
    onclick: () => { open().catch(() => {}); },
  }, icon('menu'), el('span', { class: 'u-sr-only' }, 'Menu'));
  head.prepend(button);

  panel = el('aside', { class: 'main-menu__panel', role: 'dialog', 'aria-label': 'Menu' });
  // A click on the dimmed rest of the window closes it, as with any layer.
  root = el('div', {
    class: 'main-menu', hidden: true,
    onclick: (event) => { if (event.target === root) close(); },
  }, panel);
  document.body.append(root);
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !root.hidden) close();
  });
}

async function open() {
  clearTimeout(closeTimer);
  const account = await Promise.resolve(hooks.account?.()).catch(() => null);
  render(account);
  root.hidden = false;
  // Read the layout once, so the class below starts the slide-in instead
  // of the panel simply appearing in its final place.
  void root.offsetWidth;
  root.classList.add('is-open');
  panel.querySelector('button')?.focus();
}

function close() {
  root.classList.remove('is-open');
  clearTimeout(closeTimer);
  closeTimer = setTimeout(() => { root.hidden = true; }, CLOSE_MS);
}

function item(iconName, label, action) {
  return el('button', {
    class: 'main-menu__item', type: 'button',
    onclick: () => {
      close();
      action?.();
    },
  }, icon(iconName, 'icon--sm'), el('span', { class: 'main-menu__label' }, label));
}

function render(account) {
  const avatar = el('span', { class: `avatar main-menu__avatar accent-${account?.color || 'a5'}` });
  fillAvatar(avatar, { title: account?.title || '?', avatar: account?.avatar || '' });
  // The header and the sheet matter on a phone only (layout/_phone-menu):
  // a glass pill with the title and Close, the rest in a glass sheet under
  // it, as the settings are shown there.
  clear(panel).append(
    el('div', { class: 'main-menu__head' },
      el('h2', { class: 'main-menu__title' }, 'Menu'),
      el('button', {
        class: 'btn btn--icon main-menu__close', type: 'button', title: 'Close',
        onclick: close,
      }, icon('close'), el('span', { class: 'u-sr-only' }, 'Close'))),
    el('div', { class: 'main-menu__sheet' },
    el('button', {
      class: 'main-menu__account', type: 'button', title: 'My profile',
      onclick: () => {
        close();
        hooks.profile?.();
      },
    },
    avatar,
    el('span', { class: 'main-menu__name' }, account?.title || 'Account'),
    account?.userId ? el('span', { class: 'main-menu__sub' }, String(account.userId)) : null),
    el('nav', { class: 'main-menu__items' },
      item('person', 'My profile', hooks.profile),
      item('group', 'New group', hooks.newGroup),
      item('channel', 'New channel', hooks.newChannel),
      item('phone', 'Contacts', hooks.contacts),
      item('bookmark', 'Saved messages', hooks.saved),
      item('settings', 'Settings', hooks.settings)),
    el('p', { class: 'main-menu__foot' }, `fptg v${APP_VERSION} — an unofficial Telegram client`)),
  );
}
