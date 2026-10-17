import { el } from '../core/dom.js';
import { store } from '../core/store.js';
import { fillAvatar } from '../util/avatar.js';
import { statusText } from './chat-list.js';
import { note } from './tgbox.js';
import { load } from './setkit.js';

// Люди и чаты в окнах настроек: карточка по id (из списка чатов, иначе
// users.cards), строка с кнопкой справа и выбор из списка чатов с
// поиском — для исключений приватности, чёрного списка и папок.

/** Чат из списка по id (у лички id чата = id человека). */
const chatById = (id) => store.chats.find((c) => String(c.id) === String(id));

/**
 * Карточки по id: users — люди (user_id), chats — чаты (chat_id).
 * Map 'u<id>' / 'c<id>' -> { id, title, avatar, avatarThumb, color, status }.
 */
export async function peerCards({ users = [], chats = [] }) {
  const out = new Map();
  const unknown = [];
  for (const id of users) {
    const chat = chatById(id);
    if (chat) out.set(`u${id}`, chat);
    else unknown.push(String(id));
  }
  for (const id of chats) {
    out.set(`c${id}`, chatById(id) ?? { id, title: 'Unknown chat' });
  }
  if (unknown.length) {
    try {
      const answer = await load('users.cards', { ids: [...new Set(unknown)] });
      for (const c of answer?.items ?? []) out.set(`u${c.userId}`, { ...c, id: c.userId });
    } catch {
      // Без карточек — строки с «Unknown user».
    }
  }
  for (const id of unknown) {
    if (!out.has(`u${id}`)) out.set(`u${id}`, { id, title: 'Unknown user' });
  }
  chaseAvatars(out);
  return out;
}

// Аватарки, которых ещё нет на диске: users.cards и chats.avatars их
// заказывают, а строки уже нарисованы. Несколько раз переспросить и
// вставить в те же кружки (peerLine запоминает их по карточке).
const AVATAR_RETRY_MS = 1200;
const AVATAR_RETRIES = 4;
const circles = new WeakMap();   // карточка -> кружки аватарки

async function chaseAvatars(cards) {
  const users = [];
  const chats = [];
  for (const [key, c] of cards) {
    if (c.avatar) continue;
    if (key.startsWith('u') && !chatById(c.id)) users.push(String(c.id));
    else chats.push(c.id);
  }
  if (!users.length && !chats.length) return;
  if (chats.length) load('chats.avatars', { ids: chats.map(Number) }).catch(() => {});
  for (let i = 0; i < AVATAR_RETRIES && (users.length || chats.length); i += 1) {
    await new Promise((r) => setTimeout(r, AVATAR_RETRY_MS));
    const fresh = [];
    try {
      if (users.length) fresh.push(...((await load('users.cards', { ids: users }))?.items ?? []).map((c) => ['u', c.userId, c]));
      if (chats.length) fresh.push(...((await load('chats.rows', { ids: chats.map(Number) }))?.items ?? []).map((c) => ['c', c.id, c]));
    } catch {
      return;
    }
    for (const [kind, id, c] of fresh) {
      if (!c.avatar) continue;
      const card = cards.get(`${kind}${id}`);
      if (!card) continue;
      card.avatar = c.avatar;
      for (const box of circles.get(card) ?? []) {
        if (box.isConnected) fillAvatar(box, { id, title: card.title || c.title, avatar: c.avatar, avatarThumb: c.avatarThumb || '' });
      }
      const list = kind === 'u' ? users : chats;
      const at = list.findIndex((x) => String(x) === String(id));
      if (at >= 0) list.splice(at, 1);
    }
  }
}

/** Вторая строка по умолчанию: бот — «bot», чат — его вид, человек — статус. */
function defaultSub(card) {
  if (card.bot || card.kind === 'bot') return 'bot';
  if (card.kind === 'group') return 'group';
  if (card.kind === 'channel') return 'channel';
  return card.status ? statusText(card) : '';
}

/** Строка: аватарка, имя, вторая строка, справа — узел (кнопка). */
export function peerLine(card, { sub, right } = {}) {
  const name = card.title || card.name || 'Deleted account';
  const avatar = el('span', { class: `avatar tgbox__avatar accent-${card.color || 'a5'}` });
  fillAvatar(avatar, { id: card.id ?? card.userId, title: name, avatar: card.avatar || '', avatarThumb: card.avatarThumb || '' });
  if (!circles.has(card)) circles.set(card, []);
  circles.get(card).push(avatar);
  const subText = sub ?? defaultSub(card);
  return el('div', { class: 'tgbox__peer' },
    avatar,
    el('span', { class: 'tgbox__toggle-text' },
      el('span', { class: 'tgbox__row-label' }, name),
      subText ? el('span', { class: 'tgbox__row-sub' }, subText) : null),
    right ?? null);
}

const KIND_SUB = {
  user: 'User', bot: 'Bot', group: 'Group', channel: 'Channel', self: 'Saved Messages',
};

/**
 * Выбор чатов из списка с галочками и поиском. kinds — какие виды
 * показывать (user, bot, group, channel, self). .chosen() — id строками.
 */
export function chatPicker({ kinds, exclude = new Set(), preset = [] }) {
  const chosen = new Set(preset.map(String));
  const items = store.chats.filter((c) => kinds.includes(c.kind) && !exclude.has(String(c.id)));
  const search = el('input', { class: 'tgbox__input', type: 'search', placeholder: 'Search', autocomplete: 'off' });
  const list = el('div', { class: 'tgbox__list' }, ...items.map((c) => {
    const box = el('input', { type: 'checkbox', class: 'tgbox__check', checked: chosen.has(String(c.id)) });
    box.addEventListener('change', () => {
      if (box.checked) chosen.add(String(c.id));
      else chosen.delete(String(c.id));
    });
    const name = c.title || '';
    const avatar = el('span', { class: `avatar tgbox__avatar accent-${c.color || 'a5'}` });
    fillAvatar(avatar, c);
    const line = el('label', { class: 'tgbox__peer' }, box, avatar,
      el('span', { class: 'tgbox__toggle-text' },
        el('span', { class: 'tgbox__row-label' }, name),
        el('span', { class: 'tgbox__row-sub' }, KIND_SUB[c.kind] ?? '')));
    line.dataset.name = name.toLowerCase();
    return line;
  }));
  search.addEventListener('input', () => {
    const q = search.value.trim().toLowerCase();
    for (const line of list.children) line.hidden = !!q && !line.dataset.name.includes(q);
  });
  const nodes = [
    el('div', { class: 'tgbox__search' }, el('label', { class: 'tgbox__field' }, search)),
    items.length ? list : note('No chats to choose from.'),
  ];
  return { nodes, chosen: () => [...chosen] };
}

/** Вид чата по id (для правил: человек или группа). */
export const chatKind = (id) => chatById(id)?.kind ?? 'user';
