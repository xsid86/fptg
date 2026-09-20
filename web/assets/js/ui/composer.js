import { qs, qsa } from '../core/dom.js';
import { on, emit } from '../core/bus.js';

// The message box, and the same formatting toolbar msginput.pas has.
//
// It can be the same toolbar because it is the same mechanism, not a
// lookalike: the buttons wrap the selection in Telegram's own
// MarkdownV2 (or HTML) syntax, and the server hands the whole thing to
// parseTextEntities on the way out. Nothing here knows what an entity
// is - that is the point, and it is why the two windows cannot drift
// in what they produce.
//
// Not WYSIWYG, for the same reason the native one is not: making bold
// text look bold while typing needs a real editor with its own entity
// tree, and this is a plain textarea.

let box = null;
let input = null;
let sendBtn = null;
let htmlBox = null;
let silentBox = null;
let canSend = false;

// open/close pairs, per syntax. Checked against core.telegram.org's
// Bot API formatting page rather than remembered: MarkdownV2 bold is a
// SINGLE asterisk, which is the easy one to get wrong.
const MARKUP = {
  markdown: {
    bold: ['*', '*'],
    italic: ['_', '_'],
    underline: ['__', '__'],
    strike: ['~', '~'],
    mono: ['`', '`'],
    code: ['```\n', '\n```'],
    spoiler: ['||', '||'],
  },
  html: {
    bold: ['<b>', '</b>'],
    italic: ['<i>', '</i>'],
    underline: ['<u>', '</u>'],
    strike: ['<s>', '</s>'],
    mono: ['<code>', '</code>'],
    code: ['<pre>', '</pre>'],
    spoiler: ['<tg-spoiler>', '</tg-spoiler>'],
  },
};

const isHtml = () => Boolean(htmlBox?.checked);

function updateEnabled(chat) {
  canSend = Boolean(chat) && chat.canSend !== false;
  input.disabled = !canSend;
  sendBtn.disabled = !canSend;
  for (const btn of qsa('.composer__format', box)) btn.disabled = !canSend;

  if (!chat) input.placeholder = 'Pick a chat to start writing';
  else if (!canSend) input.placeholder = 'You cannot write in this chat';
  else input.placeholder = 'Write a message';
}

// ------------------------------------------------------- formatting
function wrapSelection(open, close) {
  const start = input.selectionStart;
  const end = input.selectionEnd;
  const value = input.value;
  const chosen = value.slice(start, end);

  input.value = value.slice(0, start) + open + chosen + close + value.slice(end);
  if (chosen) {
    // Leave the result selected, so a second button can be applied on
    // top of the first without re-selecting by hand.
    input.setSelectionRange(start, start + open.length + chosen.length + close.length);
  } else {
    // Nothing selected: put the caret between the markers, ready to
    // type the formatted text straight away.
    input.setSelectionRange(start + open.length, start + open.length);
  }
  input.focus();
}

function quoteSelection() {
  const start = input.selectionStart;
  const end = input.selectionEnd;
  const value = input.value;
  const chosen = value.slice(start, end) || '';

  let replacement;
  if (isHtml()) {
    replacement = `<blockquote>${chosen}</blockquote>`;
  } else {
    // MarkdownV2 wants a '>' on EVERY line of the quote, not one pair
    // around the block.
    replacement = chosen
      ? chosen.split('\n').map((line) => `>${line}`).join('\n')
      : '>';
  }
  input.value = value.slice(0, start) + replacement + value.slice(end);
  input.setSelectionRange(start, start + replacement.length);
  input.focus();
}

function linkSelection() {
  const start = input.selectionStart;
  const end = input.selectionEnd;
  const value = input.value;
  let text = value.slice(start, end);
  if (!text) {
    text = window.prompt('Link text') ?? '';
    if (!text) return;
  }
  const url = window.prompt('Link target (https://...)') ?? '';
  if (!url) return;

  const replacement = isHtml()
    ? `<a href="${url}">${text}</a>`
    : `[${text}](${url})`;
  input.value = value.slice(0, start) + replacement + value.slice(end);
  input.setSelectionRange(start, start + replacement.length);
  input.focus();
}

/**
 * Best effort, not a parser - the same honest limitation the native
 * "Clear" button carries: a literal asterisk somebody typed as an
 * asterisk is indistinguishable from one that opens bold, and it goes
 * too.
 */
function clearSelection() {
  const start = input.selectionStart;
  const end = input.selectionEnd;
  const value = input.value;
  let chosen = value.slice(start, end);
  if (!chosen) return;

  if (isHtml()) {
    chosen = chosen.replace(/<[^>]+>/g, '');
  } else {
    chosen = chosen
      .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/^>/gm, '')
      .replace(/[*_~`|]/g, '');
  }
  input.value = value.slice(0, start) + chosen + value.slice(end);
  input.setSelectionRange(start, start + chosen.length);
  input.focus();
}

function applyFormat(kind) {
  if (kind === 'quote') return quoteSelection();
  if (kind === 'link') return linkSelection();
  if (kind === 'clear') return clearSelection();
  const pair = MARKUP[isHtml() ? 'html' : 'markdown'][kind];
  if (pair) wrapSelection(pair[0], pair[1]);
  return undefined;
}

// ------------------------------------------------------------- send
function send() {
  if (!canSend) return;
  const text = input.value;
  if (!text.trim()) return;
  emit('ui:send', { text, html: isHtml(), silent: Boolean(silentBox?.checked) });
  input.value = '';
  input.focus();
}

export function mountComposer(node) {
  box = node;
  input = qs('.composer__input', box);
  sendBtn = qs('.composer__send', box);
  htmlBox = qs('#composer-html', box);
  silentBox = qs('#composer-silent', box);

  sendBtn.addEventListener('click', send);
  input.addEventListener('keydown', (event) => {
    // Enter sends, Ctrl+Enter inserts a newline - the same split the
    // native input uses, so muscle memory carries between the two.
    if (event.key !== 'Enter' || event.ctrlKey || event.shiftKey) return;
    event.preventDefault();
    send();
  });

  for (const btn of qsa('.composer__format', box)) {
    btn.addEventListener('click', () => applyFormat(btn.dataset.fmt));
  }

  on('store:active', updateEnabled);
  updateEnabled(null);
}
