import { el, clear } from '../core/dom.js';
import { call } from '../core/net.js';
import { fillAvatar } from '../util/avatar.js';

// Подсказка упоминаний в поле ввода: набрали «@» и начало имени — над
// полем всплывает список людей (mention.search: участники группы,
// в личке — контакты). Стрелки и Enter/Tab выбирают, Escape закрывает,
// мышью — кликом.
//
// Вставляется то, что Telegram поймёт: «@username » — упоминание он
// распознаёт сам; человек без username — ссылкой tg://user?id= в
// разметке поля (MarkdownV2 или HTML), сервер пропускает её как есть
// (EscapeMarkdownV2/EscapeHtml в tdmessages.pas), и выходит
// textEntityTypeMentionName.
//
// Список — popover в верхнем слое, привязанный к полю через anchor
// positioning (как меню): у карточки композера своя рамка, и абсолютный
// блок внутри неё обрезался бы. showPopover фокус у поля не забирает.

// «@» в начале или после пробела/скобки, дальше — буквы, цифры, «_».
const TRIGGER = /(^|[\s(])@([\p{L}\p{N}_]{0,32})$/u;
// Пауза набора перед запросом: каждый запрос — поиск в Telegram.
const DEBOUNCE_MS = 150;

let input = null;
let pop = null;
let opts = {};
let items = [];
let index = 0;
let token = null;   // { start, end } — позиции «@запрос» в поле
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

/** «@запрос» прямо перед кареткой, или null. */
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
      // Фокус остаётся в поле: иначе blur закрыл бы список раньше клика.
      onmousedown: (event) => event.preventDefault(),
      onclick: () => choose(item),
    },
    avatar,
    el('span', { class: 'mention-pop__name' }, item.name || item.username || 'User'),
    item.username ? el('span', { class: 'mention-pop__username' }, `@${item.username}`) : null);
  }));
  if (!pop.matches(':popover-open')) pop.showPopover();
  pop.children[index]?.scrollIntoView({ block: 'nearest' });
}

function move(delta) {
  index = (index + delta + items.length) % items.length;
  render();
}

/** То, что встанет в поле вместо «@запрос». */
function insertion(item) {
  if (item.username) return `@${item.username} `;
  // Квадратные скобки сломали бы ссылку MarkdownV2, а сервер ищет её
  // по первой «]»; HTML-текст экранирует сервер сам.
  const name = (item.name || 'User').replace(/[[\]]/g, '');
  const id = String(item.userId).replace(/\D/g, '');
  return opts.isHtml?.()
    ? `<a href="tg://user?id=${id}">${name}</a> `
    : `[${name}](tg://user?id=${id}) `;
}

function choose(item) {
  if (!token) return;
  const text = insertion(item);
  const { start, end } = token;
  input.value = input.value.slice(0, start) + text + input.value.slice(end);
  const caret = start + text.length;
  input.setSelectionRange(caret, caret);
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
  // Раньше обработчика композера: Enter не должен отправить сообщение,
  // Escape — отменить ответ.
  event.preventDefault();
  event.stopImmediatePropagation();
}

/**
 * options: { enabled(): можно ли писать в чат, isHtml(): режим разметки }
 */
export function mountMentions(textarea, options) {
  input = textarea;
  opts = options ?? {};
  pop = el('div', { class: 'mention-pop', popover: 'manual', role: 'listbox' });
  document.body.append(pop);
  input.classList.add('mention-anchor');
  // В фазе перехвата: на самом поле она срабатывает раньше его обычных
  // обработчиков, в том числе отправки по Enter.
  input.addEventListener('keydown', onKey, true);
  input.addEventListener('input', onInput);
  input.addEventListener('blur', () => setTimeout(() => {
    if (document.activeElement !== input) close();
  }, 100));
}

/** Закрыть подсказку (смена чата, отправка). */
export function closeMentions() {
  close();
}
