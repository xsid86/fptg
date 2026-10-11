import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';

// Уведомления внутри окна приложения — как алерты Bootstrap: стопка
// сверху.
//
// Два вида:
//   * сообщения человеку (ui:notice) — ответ бота на нажатие кнопки,
//     «скопировано», «заявка отправлена», «пока не поддерживается»;
//     сами не исчезают, закрываются крестиком;
//   * ошибки запросов (ui:error) — красные и исчезают сами через
//     ERROR_TTL_MS: их бывает много, и висящий до ручного закрытия алерт
//     на каждую был бы шумом. Та же ошибка, пока видна, не плодит копию,
//     а продлевает показанную. (Раньше ошибки жили в статусной строке.)

const ERROR_TTL_MS = 8000;

let stack = null;
// Текст ошибки -> { card, timer } — показанные сейчас.
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
