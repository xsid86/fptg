import { el } from '../core/dom.js';
import { copyText } from '../util/clipboard.js';
import { notice } from './notices.js';

// A person's Telegram ID as a line under the name — in member rows (the
// info panel) and contacts (the Contacts list). A click copies. It sits
// inside a row that opens the contact on a click itself, so clicks and
// keys do not bubble further.

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
