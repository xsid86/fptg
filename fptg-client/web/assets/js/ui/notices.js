import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';

// Notices inside the app window — like Bootstrap alerts: a stack at the top.
//
// Two kinds:
//   * messages to the person (ui:notice) — a bot's answer to a button press,
//     "copied", "request sent", "not supported yet"; they do not disappear
//     by themselves, they are closed with a cross;
//   * request errors (ui:error) — red and disappear by themselves after
//     ERROR_TTL_MS: there may be many, and an alert hanging until closed by
//     hand for each would be noise. The same error, while visible, does not
//     make a copy but extends the one shown. (Errors used to live in the status bar.)

const ERROR_TTL_MS = 8000;

let stack = null;
// Error text -> { card, timer } — those shown now.
const errors = new Map();

function card(text, cls) {
  const node = el('div', { class: cls, role: cls.includes('is-error') ? 'alert' : 'status' },
    el('p', { class: 'notice__text' }, String(text)));
  node.append(el('button', {
    class: 'notice__close', type: 'button', title: 'Close',
    onclick: () => node.remove(),
  }, icon('close', 'icon--sm'), el('span', { class: 'u-sr-only' }, 'Close')));
  return node;
}

export function notice(text) {
  if (!stack || !text) return;
  stack.append(card(text, 'notice'));
}

export function errorNotice(text) {
  if (!stack || !text) return;
  const key = String(text);
  let shown = errors.get(key);
  if (shown?.card.isConnected) {
    clearTimeout(shown.timer);
  } else {
    shown = { card: card(key, 'notice is-error'), timer: 0 };
    errors.set(key, shown);
    stack.append(shown.card);
  }
  shown.timer = setTimeout(() => {
    shown.card.remove();
    errors.delete(key);
  }, ERROR_TTL_MS);
}

export function mountNotices(node) {
  stack = node;
  on('ui:notice', notice);
  on('ui:error', errorNotice);
}
