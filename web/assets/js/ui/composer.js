import { qs } from '../core/dom.js';
import { on } from '../core/bus.js';

// The message box. Enter sends, Ctrl+Enter inserts a newline - the same
// split the native input uses, so muscle memory carries between the two
// windows.
//
// Growing with the text is done by CSS (field-sizing: content), not by
// measuring scrollHeight and assigning element.style on every keystroke.
//
// Sending needs a server command that does not exist yet, so the whole
// block stays disabled until a chat is selected AND that command lands.
// Disabled and explained, rather than enabled and silently dropping
// what someone typed.

let box = null;
let input = null;
let sendBtn = null;

function updateEnabled(chat) {
  const ready = false;                 // flip when messages.send exists
  const has = Boolean(chat);
  input.disabled = !has || !ready;
  sendBtn.disabled = !has || !ready;
  input.placeholder = has
    ? 'Sending is not wired up yet'
    : 'Pick a chat to start writing';
}

export function mountComposer(node) {
  box = node;
  input = qs('.composer__input', box);
  sendBtn = qs('.composer__send', box);

  input.addEventListener('keydown', (event) => {
    if (event.key !== 'Enter' || event.ctrlKey || event.shiftKey) return;
    event.preventDefault();
    sendBtn.click();
  });

  on('store:active', updateEnabled);
  updateEnabled(null);
}
