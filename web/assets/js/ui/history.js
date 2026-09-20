import { el, clear } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';

// The message history. There is no history command on the server yet,
// so this renders the two states it genuinely has - nothing selected,
// and selected but not yet loadable - rather than pretending to show
// messages. The markup and the styling for a message block are in place
// (see blocks/_message.scss) and this is where they get used once
// history.load exists.

let root = null;

function placeholder(title, note) {
  return el('div', { class: 'workspace__empty' },
    icon('chat', 'icon--lg'),
    el('div', { textContent: title }),
    note ? el('div', { class: 'u-faint', textContent: note }) : null,
  );
}

function render(chat) {
  if (!root) return;
  clear(root);
  if (!chat) {
    root.append(placeholder('Pick a chat on the left', 'Its messages will show up here.'));
    return;
  }
  root.append(placeholder(
    chat.title || '(no title)',
    'The history command is not implemented on the server yet.',
  ));
}

export function mountHistory(node) {
  root = node;
  on('store:active', render);
  render(null);
}
