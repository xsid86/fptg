import { el, clear } from '../core/dom.js';
import { fillAvatar } from '../util/avatar.js';
import { clockTime, dateLabel } from '../util/format.js';

// Кто поставил реакцию и кто прочитал — всплывающий список по наведению:
// аватарка 16x16, имя, время.
//
// Telegram отдаёт эти списки не везде, и лишних вопросов не задаётся:
//   * реакции — только где can_get_added_reactions; этот флаг приходит
//     с самим сообщением, и без него список на чип не вешается вовсе;
//   * «кто прочитал» — сервер сначала проверяет can_get_viewers /
//     can_get_read_date (getMessageProperties). «Нельзя» запоминается
//     здесь по сообщению, и больше оно не спрашивается; «можно» —
//     тоже, и дальше уходит сразу запрос списка (checked).
// Окно появляется, только когда есть ответ; нельзя или ошибка — его
// нет совсем, без «Loading…» и без текста отказа.
//
// Popover вне потока, как меню и панель эмодзи: верхний слой, ничего
// его не обрежет. Место — anchor positioning от того, на что навели
// (.is-people-anchor, blocks/_people.scss).

const SHOW_DELAY_MS = 350;   // мимолётное касание курсором — не повод спрашивать сервер
const HIDE_DELAY_MS = 200;   // успеть перевести курсор с чипа на сам список

let hooks = {};
let panel = null;
let anchor = null;
let showTimer = 0;
let hideTimer = 0;
let asked = 0;               // номер запроса: ответ на прежнее наведение отбрасывается
// id сообщения -> можно ли спрашивать, кто его прочитал (ответ сервера).
const viewersAllowed = new Map();

function ensurePanel() {
  if (panel) return panel;
  panel = el('div', { class: 'people', popover: 'manual' });
  // Курсор, ушедший с чипа на список, не должен его закрыть.
  panel.addEventListener('pointerenter', () => clearTimeout(hideTimer));
  panel.addEventListener('pointerleave', scheduleHide);
  document.body.append(panel);
  return panel;
}

function when(unix) {
  if (!unix) return '';
  const day = dateLabel(unix);
  const time = clockTime(unix);
  return day === 'Today' ? time : `${day}, ${time}`;
}

function personRow(p) {
  const avatar = el('span', { class: `avatar people__avatar accent-${p.color || 'f0'}` });
  fillAvatar(avatar, { title: p.name || '?', avatar: p.avatar, avatarThumb: p.avatarThumb });
  return el('li', { class: 'people__item' },
    avatar,
    el('span', { class: 'people__name' }, p.name || 'Loading…'),
    p.date ? el('span', { class: 'people__time u-tabular' }, when(p.date)) : null);
}

function draw(content) {
  clear(panel).append(...content);
}

async function show(target, args, title) {
  const viewers = args.what === 'viewers';
  if (viewers && viewersAllowed.get(args.id) === false) return;
  const my = ++asked;

  let data;
  try {
    data = await hooks.load(viewers && viewersAllowed.get(args.id) ? { ...args, checked: true } : args);
  } catch {
    return;              // отказ Telegram — окна нет
  }
  if (viewers) viewersAllowed.set(args.id, data?.allowed !== false);
  if (data?.allowed === false) return;
  // Курсор ушёл, пока ждали ответа, или навёлся на другое.
  if (my !== asked || !target.matches(':hover')) return;

  ensurePanel();
  anchor?.classList.remove('is-people-anchor');
  anchor = target;
  anchor.classList.add('is-people-anchor');

  const items = data?.items ?? [];
  const body = [el('div', { class: 'people__title' },
    data?.total > items.length ? `${title} · ${data.total}` : title)];
  if (items.length) {
    body.push(el('ul', { class: 'people__list' }, ...items.map(personRow)));
  } else {
    body.push(el('p', { class: 'people__note' }, data?.note || 'Nobody yet'));
  }
  draw(body);
  try { panel.showPopover(); } catch { /* уже открыт */ }
}

function hide() {
  asked += 1;
  anchor?.classList.remove('is-people-anchor');
  anchor = null;
  try { panel?.hidePopover(); } catch { /* уже закрыт */ }
}

function scheduleHide() {
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  hideTimer = setTimeout(hide, HIDE_DELAY_MS);
}

/**
 * Вешает список на узел: args — то, что уйдёт в message.people
 * ({id, what: 'reactions' | 'viewers', emoji?, customEmojiId?}), title —
 * заголовок списка.
 */
export function peopleOnHover(node, args, title) {
  node.addEventListener('pointerenter', () => {
    clearTimeout(hideTimer);
    clearTimeout(showTimer);
    showTimer = setTimeout(() => show(node, args, title).catch(console.error), SHOW_DELAY_MS);
  });
  node.addEventListener('pointerleave', scheduleHide);
}

/** hooks: { load(args) } — запрос message.people через main.js. */
export function mountPeople(options) {
  hooks = options ?? {};
}
