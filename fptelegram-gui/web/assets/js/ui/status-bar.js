import { qs, clear, el, append } from '../core/dom.js';
import { on } from '../core/bus.js';
import { call } from '../core/net.js';
import { store } from '../core/store.js';
import { fillAvatar } from '../util/avatar.js';
import { openMenu } from '../util/menu.js';
import { formDialog } from './bots.js';
import { fileSize } from '../util/format.js';
import { openSettings } from './settings.js';

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

function renderStatus(status) {
  conn.className = `conn is-${status}`;
  clear(conn).append(
    el('span', { class: 'conn__dot' }),
    el('span', { class: 'conn__label', textContent: LABEL[status] ?? status }),
  );
}

// «Online» — всегда: режима «Невидимка» больше нет (2026-10-12, условия
// Telegram API §1.4 — нельзя прятать онлайн и не отмечать прочитанное).
// Кто видит «в сети» и время прочтения — официальные настройки
// приватности, клик ведёт прямо в них (Settings → Privacy).
function renderPresence() {
  presence.title = 'Who can see your last seen, online status and read time: '
    + 'Settings → Privacy';
  clear(presence).append(
    el('span', { class: 'conn__dot' }),
    el('span', { textContent: 'Online' }),
  );
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

// ---------------------------------------------------------- traffic
// Трафик ЭТОГО окна с сервером под Online. Считает сервер — по
// сеансу входа, с запуска сервера — и присылает итог раз в секунду
// (событие traffic: sent/recv со стороны сервера); скорость — по
// разнице двух соседних итогов. ↓ получено окном, ↑ отправлено.
let traffic = null;
let prevTraffic = null;

// Показывать ли строку — Settings → General. Настройка вида этого окна,
// а не сервера: локально, как выбор темы. Нет записи — показывать.
const TRAFFIC_KEY = 'showTraffic';

export function trafficShown() {
  try {
    return localStorage.getItem(TRAFFIC_KEY) !== '0';
  } catch {
    return true;
  }
}

export function setTrafficShown(on) {
  try {
    localStorage.setItem(TRAFFIC_KEY, on ? '1' : '0');
  } catch {
    // Не запомнится до следующего запуска, но сейчас подействует.
  }
  // Спрятать сразу; показать — как только придёт следующий итог.
  if (traffic && !on) traffic.hidden = true;
}

function renderTraffic(data) {
  const now = performance.now();
  const down = Number(data?.sent) || 0;
  const up = Number(data?.recv) || 0;
  let downSpeed = 0;
  let upSpeed = 0;
  const p = prevTraffic;
  if (p && now > p.t && down >= p.down && up >= p.up) {
    const dt = (now - p.t) / 1000;
    downSpeed = Math.round((down - p.down) / dt);
    upSpeed = Math.round((up - p.up) / dt);
  }
  prevTraffic = { t: now, down, up };
  traffic.hidden = !trafficShown();
  traffic.textContent = `↓ ${fileSize(down)} · ${fileSize(downSpeed)}/s  `
    + `↑ ${fileSize(up)} · ${fileSize(upSpeed)}/s`;
}

export function mountStatusBar(node) {
  conn = qs('.conn', node);
  counts = qs('.status-bar__counts', node);
  presence = qs('.status-bar__presence', node);
  presence.addEventListener('click', () => openSettings('privacy'));
  traffic = qs('.status-bar__traffic', node);
  traffic.title = 'Traffic of this window with the server (this sign-in, '
    + 'since the server started): ↓ received, ↑ sent';
  on('srv:traffic', renderTraffic);
  accountBtn = qs('.status-bar__account', node);
  accountBtn.hidden = true;
  accountBtn.addEventListener('click', () => openAccounts());
  on('srv:accounts', () => loadAccounts());
  // Активный аккаунт сменился (здесь, в другом окне или после выхода).
  on('srv:account', () => window.location.reload());
  on('net:status', (status) => {
    renderStatus(status);
    // Без связи прежний итог не сравнивать — скорость начнётся заново.
    if (status !== 'open') prevTraffic = null;
    if (status === 'open') loadAccounts();
  });
  on('store:chats', renderCounts);
  renderStatus('connecting');
  renderPresence();
  renderCounts();
}
