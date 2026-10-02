import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';

// Уведомления внутри окна приложения — как алерты Bootstrap: стопка
// сверху, каждое само не исчезает, закрывается только крестиком.
//
// Для сообщений, адресованных человеку: ответ бота на нажатие кнопки,
// «скопировано», «заявка отправлена», «пока не поддерживается».
// Ошибки запросов остаются в статусной строке (ui:error) — их бывает
// много, и висящий до ручного закрытия алерт на каждую был бы шумом.
//
// Любой модуль шлёт их событием ui:notice с текстом.

let stack = null;

export function notice(text) {
  if (!stack || !text) return;
  const card = el('div', { class: 'notice', role: 'status' },
    el('p', { class: 'notice__text' }, String(text)));
  card.append(el('button', {
    class: 'notice__close', type: 'button', title: 'Close',
    onclick: () => card.remove(),
  }, icon('close', 'icon--sm'), el('span', { class: 'u-sr-only' }, 'Close')));
  stack.append(card);
}

export function mountNotices(node) {
  stack = node;
  on('ui:notice', notice);
}
