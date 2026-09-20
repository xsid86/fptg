import { el, clear } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon, kindIcon } from '../util/icons.js';
import { initial } from '../util/format.js';

// The bar above the history. The filter strip mirrors chatheader.pas;
// the toggles are rendered and clickable, but nothing is wired to a
// server command yet - there is no history to filter until the history
// commands exist, and a control that silently does nothing is worse
// than one that says so, hence the title text.

const FILTERS = [
  ['image', 'Photos'],
  ['video', 'Videos'],
  ['gif', 'GIFs'],
  ['audio', 'Music'],
  ['mic', 'Voice messages'],
  ['file', 'Files'],
  ['link', 'Links'],
  ['poll', 'Polls'],
  ['pin', 'Pinned'],
  ['gift', 'Gifts'],
  ['bookmark', 'Saved'],
];

let root = null;

function filterStrip() {
  return el('div', { class: 'chat-header__filters' },
    FILTERS.map(([name, label]) => el('button', {
      class: 'chat-filter',
      type: 'button',
      title: `${label} (not wired up yet)`,
      disabled: true,
    }, icon(name, 'icon--sm'), el('span', { class: 'u-sr-only', textContent: label }))),
  );
}

function render(chat) {
  if (!root) return;
  clear(root);
  if (!chat) {
    // Drop the previous chat's accent class too, so a hidden header
    // cannot come back wearing the wrong colour.
    root.className = 'chat-header';
    root.hidden = true;
    return;
  }
  root.hidden = false;
  // Same palette class the list row carries, so the header and the row
  // for one chat can never disagree about its colour.
  root.className = `chat-header accent-${chat.color}`;

  root.append(
    el('button', { class: 'btn btn--icon chat-header__back', type: 'button', title: 'Back' },
      icon('chevron-left')),
    el('span', { class: 'avatar avatar--lg chat-header__avatar', textContent: initial(chat.title) }),
    el('div', { class: 'chat-header__identity' },
      el('div', { class: 'chat-header__title' },
        icon(kindIcon(chat.kind), 'icon--sm'),
        el('span', { class: 'u-ellipsis', textContent: chat.title || '(no title)' })),
      el('div', { class: 'chat-header__subtitle', textContent: subtitle(chat) })),
    el('div', { class: 'chat-header__tools' },
      el('label', { class: 'field chat-header__search' },
        icon('search', 'icon--sm'),
        el('input', {
          class: 'field__input',
          type: 'search',
          placeholder: 'Search...',
          disabled: true,
          title: 'Search is not wired up yet',
        })),
      filterStrip()),
  );
}

function subtitle(chat) {
  const parts = [chat.kind];
  if (chat.folder) parts.push(chat.folder);
  if (chat.unread > 0) parts.push(`${chat.unread} unread`);
  return parts.join(' \u00b7 ');
}

export function mountChatHeader(node) {
  root = node;
  on('store:active', render);
  render(null);
}
