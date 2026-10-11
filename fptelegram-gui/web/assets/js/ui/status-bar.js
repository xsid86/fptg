import { qs, clear, el, append } from '../core/dom.js';
import { on } from '../core/bus.js';
import { call } from '../core/net.js';
import { store } from '../core/store.js';
import { fillAvatar } from '../util/avatar.js';
import { openMenu } from '../util/menu.js';
import { formDialog } from './bots.js';

// Connection state and a couple of counters. Deliberately the only
// place that reports the socket: a status that appears in two places
// eventually disagrees with itself.

const LABEL = {
  connecting: 'connecting...',
  open: 'connected',
  closed: 'disconnected',
};

let conn = null;
let counts = null;
let presence = null;
// What the server last said. Never guessed from the click: the switch
// is remembered on disk and shared with the native window, so the
// answer is the only thing that knows.
let invisible = false;

function renderStatus(status) {
  conn.className = `conn is-${status}`;
  clear(conn).append(
    el('span', { class: 'conn__dot' }),
    el('span', { class: 'conn__label', textContent: LABEL[status] ?? status }),
  );
}

// Online or Invisible, the same switch the native window keeps in its
// status bar - and in the same corner, because that is where it has
// always been.
//
// Invisible is not decoration: while it is on, nothing this client
// reads is reported back (viewMessages is withheld in the model) and
// contacts are not shown an online presence. So it says which one is
// on in words, not only by colour.
function renderPresence() {
  presence.classList.toggle('is-invisible', invisible);
  presence.title = invisible
    ? 'Invisible: messages are not marked as read and contacts do not see you online'
    : 'Online: reading a chat marks its messages as read';
  clear(presence).append(
    el('span', { class: 'conn__dot' }),
    el('span', { textContent: invisible ? 'Invisible' : 'Online' }),
  );
}

async function loadPresence() {
  try {
    const answer = await call('presence.get');
    invisible = !!answer.invisible;
  } catch {
    return;                       // the connection will say so itself
  }
  renderPresence();
}

async function togglePresence() {
  presence.disabled = true;
  try {
    const answer = await call('presence.set', { invisible: !invisible });
    invisible = !!answer.invisible;
    renderPresence();
  } catch (error) {
    showError(error.message);
  } finally {
    presence.disabled = false;
  }
}

function renderCounts() {
  const total = store.chats.length;
  const unread = store.chats.reduce((sum, c) => sum + (c.unread || 0), 0);
  clear(counts).append(
    el('span', { class: 'status-bar__item u-tabular', textContent: `${total} chats` }),
    el('span', { class: 'status-bar__item u-tabular', textContent: `${unread} unread` }),
  );
}

// ---------------------------------------------------------- accounts
// Переключатель аккаунтов — между состоянием соединения и видимостью.
// Список и активный аккаунт держит сервер (accounts.list, реестр tdcore);
// смена активного приходит событием account, и страница перезагружается:
// у другого аккаунта другие чаты, история, снимки — смешать их нельзя, а
// чистый старт гарантирует это проще всего.
let accountBtn = null;
let accounts = { active: 0, accounts: [], canAdd: false };

function accountAvatar(a, cls) {
  const box = el('span', { class: `avatar ${cls} accent-${a.color || 'a5'}` });
  fillAvatar(box, { title: a.title || '?', avatar: a.avatar || '' });
  return box;
}

function renderAccountButton() {
  const a = accounts.accounts.find((x) => x.index === accounts.active);
  if (!a) {
    accountBtn.hidden = true;
    return;
  }
  accountBtn.hidden = false;
  accountBtn.title = accounts.accounts.length > 1 ? 'Switch account' : 'Account';
  // append из dom.js, не родной: тот превращает null в текст «null».
  append(clear(accountBtn), [
    accountAvatar(a, 'status-bar__account-avatar'),
    el('span', { class: 'status-bar__account-text' },
      el('span', { class: 'status-bar__account-name' }, a.title || 'Account'),
      a.userId ? el('span', { class: 'status-bar__account-id' }, a.userId) : null),
    // Непрочитанное в ДРУГИХ аккаунтах — точкой: по своему счётчик рядом.
    accounts.accounts.some((x) => x.index !== accounts.active && x.unread > 0)
      ? el('span', { class: 'status-bar__account-dot', title: 'Unread messages in other accounts' })
      : null,
  ]);
}

async function loadAccounts() {
  try {
    accounts = await call('accounts.list');
  } catch {
    return;                       // the connection will say so itself
  }
  renderAccountButton();
}

async function accountCall(cmd, args) {
  try {
    await call(cmd, args);
  } catch (error) {
    showError(error.message);
  }
}

function accountRow(a) {
  const sub = !a.ready
    ? 'Not signed in'
    : (a.username ? `@${a.username}` : (a.phone ? `+${a.phone}` : ''));
  return el('span', { class: 'account-row' },
    accountAvatar(a, 'account-row__avatar'),
    el('span', { class: 'account-row__text' },
      el('span', { class: 'account-row__name' }, a.title || 'Account'),
      sub ? el('span', { class: 'account-row__sub' }, sub) : null),
    a.unread > 0 ? el('span', { class: 'account-row__unread' }, String(a.unread)) : null);
}

function openAccounts() {
  const items = accounts.accounts.map((a) => ({
    node: accountRow(a),
    className: 'menu__item--account',
    checked: a.index === accounts.active,
    onSelect: () => {
      if (a.index !== accounts.active) accountCall('accounts.switch', { index: a.index });
    },
  }));
  items.push('-');
  items.push({
    label: 'Add account', disabled: !accounts.canAdd,
    onSelect: () => accountCall('accounts.add'),
  });
  items.push({
    label: 'Log out',
    onSelect: async () => {
      const a = accounts.accounts.find((x) => x.index === accounts.active);
      const more = accounts.accounts.length > 1;
      const yes = await formDialog({
        text: more
          ? `Log out of ${a?.title || 'this account'}? It will be removed from the list.`
          : `Log out of ${a?.title || 'this account'}?`,
        ok: 'Log out',
      });
      if (yes) accountCall('accounts.logout');
    },
  });
  openMenu(accountBtn, items);
}

let errorTimer = null;

function showError(message) {
  // После переключателя видимости, а не после индикатора соединения:
  // тот живёт в узкой колонке под «transport check».
  let slot = qs('.status-bar__error', presence.parentElement);
  if (!slot) {
    slot = el('span', { class: 'status-bar__error' });
    presence.after(slot);
  }
  slot.textContent = message;
  // Cleared after a while rather than left standing: a stale failure
  // next to a working connection reads as a current one.
  clearTimeout(errorTimer);
  errorTimer = setTimeout(() => { slot.textContent = ''; }, 6000);
}

export function mountStatusBar(node) {
  conn = qs('.conn', node);
  counts = qs('.status-bar__counts', node);
  presence = qs('.status-bar__presence', node);
  presence.addEventListener('click', togglePresence);
  accountBtn = qs('.status-bar__account', node);
  accountBtn.hidden = true;
  accountBtn.addEventListener('click', () => openAccounts());
  on('srv:accounts', () => loadAccounts());
  // Активный аккаунт сменился (здесь, в другом окне или после выхода).
  on('srv:account', () => window.location.reload());
  on('net:status', (status) => {
    renderStatus(status);
    // Asked again on every connect, not once at start-up: another page
    // - or the native window - may have flipped it while this one was
    // away, and the server is the one that knows.
    if (status === 'open') {
      loadPresence();
      loadAccounts();
    }
  });
  on('srv:presence', (data) => {
    invisible = !!data?.invisible;
    renderPresence();
  });
  on('store:chats', renderCounts);
  on('ui:error', showError);
  renderStatus('connecting');
  renderPresence();
  renderCounts();
}
