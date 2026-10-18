import { el, clear } from '../core/dom.js';
import { call } from '../core/net.js';
import { fillAvatar } from '../util/avatar.js';
import { markPopDirection } from '../util/pop.js';

// Mention suggestions in the input field: typed "@" and the start of a name
// — a list of people pops up above the field (mention.search: group
// members, in a private chat — contacts). The arrows and Enter/Tab choose,
// Escape closes, with the mouse — a click.
//
// What gets inserted is what Telegram understands: "@username " — it
// recognizes the mention itself; a person without a username — their name
// with a mentionName entity (ui/editor.js -> textEntityTypeMentionName).
//
// The list is a popover in the top layer tied to the field through anchor
// positioning (like the menu): the composer card has its own frame, and an
// absolute block inside it would be clipped. showPopover does not take the
// field's focus.

// "@" at the start or after a space/bracket, then letters, digits, "_".
const TRIGGER = /(^|[\s(])@([\p{L}\p{N}_]{0,32})$/u;
// The typing pause before a request: each request is a search on Telegram.
const DEBOUNCE_MS = 150;

let input = null;
let pop = null;
let opts = {};
let items = [];
let index = 0;
let token = null;   // { start, end } — the positions of "@query" in the field
let seq = 0;
let timer = 0;

function close() {
  clearTimeout(timer);
  seq += 1;
  token = null;
  items = [];
  if (pop?.matches(':popover-open')) pop.hidePopover();
}

const isOpen = () => Boolean(pop?.matches(':popover-open') && items.length);

/** "@query" right before the caret, or null. */
function tokenAtCaret() {
  if (input.selectionStart !== input.selectionEnd) return null;
  const caret = input.selectionStart;
  const m = TRIGGER.exec(input.value.slice(0, caret));
  if (!m) return null;
  return { start: caret - m[2].length - 1, end: caret, query: m[2] };
}

function onInput() {
  if (!opts.enabled?.()) {
    close();
    return;
  }
  const t = tokenAtCaret();
  if (!t) {
    close();
    return;
  }
  token = t;
  clearTimeout(timer);
  timer = setTimeout(() => search(t.query), DEBOUNCE_MS);
}

async function search(query) {
  const my = ++seq;
  let answer;
  try {
    answer = await call('mention.search', { query });
  } catch {
    return;
  }
  if (my !== seq || !token) return;
  items = answer?.items ?? [];
  index = 0;
  render();
}

function render() {
  if (!items.length) {
    if (pop.matches(':popover-open')) pop.hidePopover();
    return;
  }
  clear(pop).append(...items.map((item, i) => {
    const avatar = el('span', { class: `avatar mention-pop__avatar accent-${item.color || 'a5'}` });
    fillAvatar(avatar, {
      id: item.userId, title: item.name || item.username || '?',
      avatar: item.avatar || '', avatarThumb: item.avatarThumb || '',
    });
    return el('button', {
      class: `mention-pop__item${i === index ? ' is-active' : ''}`,
      type: 'button',
      role: 'option',
      // Focus stays in the field: otherwise blur would close the list before the click.
      onmousedown: (event) => event.preventDefault(),
      onclick: () => choose(item),
    },
    avatar,
    el('span', { class: 'mention-pop__name' }, item.name || item.username || 'User'),
    item.username ? el('span', { class: 'mention-pop__username' }, `@${item.username}`) : null);
  }));
  if (!pop.matches(':popover-open')) {
    pop.showPopover();
    markPopDirection(pop, input);
  }
  pop.children[index]?.scrollIntoView({ block: 'nearest' });
}

function move(delta) {
  index = (index + delta + items.length) % items.length;
  render();
}

function choose(item) {
  if (!token) return;
  const { start, end } = token;
  const id = String(item.userId).replace(/\D/g, '');
  if (item.username) input.replaceRange(start, end, `@${item.username} `);
  else input.insertMention(start, end, item.name || 'User', id);
  input.focus();
  close();
}

function onKey(event) {
  if (!isOpen()) return;
  let handled = true;
  if (event.key === 'ArrowDown') move(1);
  else if (event.key === 'ArrowUp') move(-1);
  else if (event.key === 'Enter' || event.key === 'Tab') choose(items[index]);
  else if (event.key === 'Escape') close();
  else handled = false;
  if (!handled) return;
  // Before the composer's handler: Enter must not send the message, Escape
  // must not cancel the reply.
  event.preventDefault();
  event.stopImmediatePropagation();
}

/**
 * editor — the input field (ui/editor.js); options: { enabled(): whether
 * one may write to the chat }
 */
export function mountMentions(editor, options) {
  input = editor;
  opts = options ?? {};
  pop = el('div', { class: 'mention-pop', popover: 'manual', role: 'listbox' });
  document.body.append(pop);
  input.classList.add('mention-anchor');
  // In the capture phase: on the field itself it fires before its ordinary
  // handlers, including sending on Enter.
  input.addEventListener('keydown', onKey, true);
  input.addEventListener('input', onInput);
  input.addEventListener('blur', () => setTimeout(() => {
    if (document.activeElement !== input) close();
  }, 100));
}

/** Close the suggestion (a chat change, sending). */
export function closeMentions() {
  close();
}
