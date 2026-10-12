import { el } from '../core/dom.js';
import { copyText } from '../util/clipboard.js';
import { notice } from './notices.js';

// Telegram ID человека строкой под именем — в строках участников
// (инфопанель) и контактов (список Contacts). Клик копирует. Стоит
// внутри строки, которая сама по клику открывает контакт, поэтому клик
// и клавиши дальше не всплывают.

function copy(event, id) {
  event.stopPropagation();
  event.preventDefault();
  copyText(id).then(() => notice('ID copied to clipboard')).catch(() => {});
}

export function userIdNode(id) {
  const text = String(id || '');
  if (!text || text === '0') return null;
  return el('span', {
    class: 'user-id',
    role: 'button',
    tabIndex: 0,
    title: 'Copy ID',
    onclick: (event) => copy(event, text),
    onkeydown: (event) => {
      if (event.key === 'Enter' || event.key === ' ') copy(event, text);
    },
  }, text);
}
