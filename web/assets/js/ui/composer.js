import { qs, qsa } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, onActiveChat } from '../core/store.js';

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
let emojiBtn = null;
let htmlBox = null;
let silentBox = null;
let banner = null;
let canSend = false;
// What the next send is: a plain message, an answer to one, or a
// rewrite of one. { mode: 'reply' | 'edit', msg, chatId }.
//
// The chat is noted because a message object does not carry one - it is
// always the open chat's - and a reply left over from another chat
// would be sent to the wrong place.
let pending = null;

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

/** The Silent toggle, for anything sent from outside this module. */
export const isSilent = () => Boolean(silentBox?.checked);

/** A line that says which message, in as few words as the message allows. */
function describe(msg) {
  if (msg.text) return msg.text;
  const kind = msg.kind && msg.kind !== 'text' ? msg.kind : 'message';
  return kind.charAt(0).toUpperCase() + kind.slice(1);
}

function drawBanner() {
  if (!banner) return;
  banner.hidden = !pending;
  if (!pending) return;
  qs('.composer__banner-kind', banner).textContent =
    pending.mode === 'edit' ? 'Editing' : 'Reply to';
  qs('.composer__banner-text', banner).textContent = describe(pending.msg);
}

/** Drops whatever the composer was about to answer or rewrite. */
export function cancelPending() {
  if (!pending) return;
  const wasEdit = pending.mode === 'edit';
  pending = null;
  drawBanner();
  // An abandoned edit takes its text with it: leaving the old message
  // sitting in the box would be the next thing sent by accident.
  if (wasEdit) input.value = '';
  input.focus();
}

/** Answers a message. The text box keeps whatever was already typed. */
export function replyTo(msg) {
  if (!canSend) return;
  pending = { mode: 'reply', msg, chatId: store.activeChatId };
  drawBanner();
  input.focus();
}

/**
 * Rewrites a message.
 *
 * The box is filled with the message's PLAIN text, and that is what
 * will be sent: any bold, link or code the original carried is not
 * reconstructed, so saving turns it into what is on screen. That is
 * the honest behaviour for a plain textarea - what is shown is what
 * goes - but it does mean an edit can flatten formatting. Rebuilding
 * MarkdownV2 out of the entities is the fix, and it is a job of its
 * own (see TODO.md).
 */
export function editMessage(msg) {
  if (!canSend) return;
  pending = { mode: 'edit', msg, chatId: store.activeChatId };
  input.value = msg.text ?? '';
  drawBanner();
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

function updateEnabled(chat) {
  canSend = Boolean(chat) && chat.canSend !== false;
  input.disabled = !canSend;
  sendBtn.disabled = !canSend;
  for (const btn of qsa('.composer__format', box)) btn.disabled = !canSend;
  if (emojiBtn) emojiBtn.disabled = !canSend;

  // A reply belongs to the chat it was written in, and so does an
  // edit. Carrying either into another chat would send it to the wrong
  // place.
  if (pending && (!chat || pending.chatId !== chat.id)) {
    pending = null;
    drawBanner();
  }

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

/**
 * Drops text in at the caret, replacing whatever is selected - what the
 * emoji panel needs, and the only way into this box from outside.
 *
 * Note what it does NOT do: escape anything. An emoji carries no
 * MarkdownV2 meaning, and neither does any other character this is used
 * for today. The day something with meaning is inserted here, escaping
 * belongs at that call site, not in this function.
 */
export function insertAtCaret(text) {
  if (!canSend || !text) return;
  const start = input.selectionStart;
  const end = input.selectionEnd;
  input.value = input.value.slice(0, start) + text + input.value.slice(end);
  const caret = start + text.length;
  input.setSelectionRange(caret, caret);
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

  if (pending?.mode === 'edit') {
    emit('ui:edit', { id: String(pending.msg.id), text, html: isHtml() });
  } else {
    emit('ui:send', {
      text,
      html: isHtml(),
      silent: Boolean(silentBox?.checked),
      replyTo: pending?.mode === 'reply' ? String(pending.msg.id) : '',
    });
  }
  pending = null;
  drawBanner();
  input.value = '';
  input.focus();
}

export function mountComposer(node) {
  box = node;
  input = qs('.composer__input', box);
  sendBtn = qs('.composer__send', box);
  emojiBtn = qs('.composer__emoji', box);
  htmlBox = qs('#composer-html', box);
  silentBox = qs('#composer-silent', box);
  banner = qs('.composer__banner', box);

  sendBtn.addEventListener('click', send);
  qs('.composer__banner-cancel', banner)?.addEventListener('click', cancelPending);
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && pending) {
      event.preventDefault();
      cancelPending();
      return;
    }
    // Enter sends, Ctrl+Enter inserts a newline - the same split the
    // native input uses, so muscle memory carries between the two.
    if (event.key !== 'Enter' || event.ctrlKey || event.shiftKey) return;
    event.preventDefault();
    send();
  });

  for (const btn of qsa('.composer__format', box)) {
    btn.addEventListener('click', () => applyFormat(btn.dataset.fmt));
  }

  onActiveChat(updateEnabled);
  updateEnabled(null);
}
