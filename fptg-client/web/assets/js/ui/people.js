import { el, clear } from '../core/dom.js';
import { fillAvatar } from '../util/avatar.js';
import { markPopDirection } from '../util/pop.js';
import { clockTime, dateLabel } from '../util/format.js';

// Who reacted and who read — a pop-up list on hover: a 16x16 avatar, a
// name, the time.
//
// Telegram does not give these lists everywhere, and no needless questions
// are asked:
//   * reactions — only where can_get_added_reactions; that flag comes with
//     the message itself, and without it no list is hung on the chip at all;
//   * "who read it" — the server first checks can_get_viewers /
//     can_get_read_date (getMessageProperties). "Not allowed" is remembered
//     here per message, and it is not asked again; "allowed" — too, and
//     after that the list request goes at once (checked).
// The window appears only when there is an answer; not allowed or an error
// — there is none at all, without "Loading…" and without a refusal text.
//
// A popover outside the flow, like the menu and the emoji panel: the top
// layer, nothing clips it. The place — anchor positioning from what was
// hovered (.is-people-anchor, blocks/_people.scss).

const SHOW_DELAY_MS = 350;   // a fleeting touch of the cursor is no reason to ask the server
const HIDE_DELAY_MS = 200;   // time to move the cursor from the chip to the list itself

let hooks = {};
let panel = null;
let anchor = null;
let showTimer = 0;
let hideTimer = 0;
let asked = 0;               // the request number: an answer to a previous hover is discarded
// message id -> whether one may ask who read it (the server's answer).
const viewersAllowed = new Map();

function ensurePanel() {
  if (panel) return panel;
  panel = el('div', { class: 'people', popover: 'manual' });
  // A cursor that went from the chip to the list must not close it.
  panel.addEventListener('pointerenter', () => clearTimeout(hideTimer));
  panel.addEventListener('pointerleave', scheduleHide);
  document.body.append(panel);
  return panel;
}

function when(unix) {
  if (!unix) return '';
  const day = dateLabel(unix);
  const time = clockTime(unix);
  return day === 'Today' ? time : `${day}, ${time}`;
}

function personRow(p) {
  const avatar = el('span', { class: `avatar people__avatar accent-${p.color || 'f0'}` });
  fillAvatar(avatar, { title: p.name || '?', avatar: p.avatar, avatarThumb: p.avatarThumb });
  return el('li', { class: 'people__item' },
    avatar,
    el('span', { class: 'people__name' }, p.name || 'Loading…'),
    p.date ? el('span', { class: 'people__time u-tabular' }, when(p.date)) : null);
}

function draw(content) {
  clear(panel).append(...content);
}

async function show(target, args, title) {
  const viewers = args.what === 'viewers';
  if (viewers && viewersAllowed.get(args.id) === false) return;
  const my = ++asked;

  let data;
  try {
    data = await hooks.load(viewers && viewersAllowed.get(args.id) ? { ...args, checked: true } : args);
  } catch {
    return;              // Telegram refused — no window
  }
  if (viewers) viewersAllowed.set(args.id, data?.allowed !== false);
  if (data?.allowed === false) return;
  // The cursor left while we waited for the answer, or hovered something else.
  if (my !== asked || !target.matches(':hover')) return;

  ensurePanel();
  anchor?.classList.remove('is-people-anchor');
  anchor = target;
  anchor.classList.add('is-people-anchor');

  const items = data?.items ?? [];
  const body = [el('div', { class: 'people__title' },
    data?.total > items.length ? `${title} · ${data.total}` : title)];
  if (items.length) {
    body.push(el('ul', { class: 'people__list' }, ...items.map(personRow)));
  } else {
    body.push(el('p', { class: 'people__note' }, data?.note || 'Nobody yet'));
  }
  draw(body);
  if (!panel.matches(':popover-open')) {
    panel.showPopover();
    markPopDirection(panel, anchor);
  }
}

function hide() {
  asked += 1;
  anchor?.classList.remove('is-people-anchor');
  anchor = null;
  try { panel?.hidePopover(); } catch { /* already closed */ }
}

function scheduleHide() {
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  hideTimer = setTimeout(hide, HIDE_DELAY_MS);
}

/**
 * Hangs the list on a node: args — what goes into message.people
 * ({id, what: 'reactions' | 'viewers', emoji?, customEmojiId?}), title —
 * the list's heading.
 */
export function peopleOnHover(node, args, title) {
  node.addEventListener('pointerenter', () => {
    clearTimeout(hideTimer);
    clearTimeout(showTimer);
    showTimer = setTimeout(() => show(node, args, title).catch(console.error), SHOW_DELAY_MS);
  });
  node.addEventListener('pointerleave', scheduleHide);
}

/** hooks: { load(args) } — the message.people request through main.js. */
export function mountPeople(options) {
  hooks = options ?? {};
}
