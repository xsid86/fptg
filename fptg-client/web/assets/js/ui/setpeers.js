import { el } from '../core/dom.js';
import { store } from '../core/store.js';
import { fillAvatar } from '../util/avatar.js';
import { statusText } from './chat-list.js';
import { note } from './tgbox.js';
import { load } from './setkit.js';

// People and chats in the settings windows: a card by id (from the chat
// list, otherwise users.cards), a row with a button on the right and a
// choice from the chat list with search — for privacy exceptions, the
// block list and folders.

/** A chat from the list by id (a private chat's id = the person's id). */
const chatById = (id) => store.chats.find((c) => String(c.id) === String(id));

/**
 * Cards by id: users — people (user_id), chats — chats (chat_id).
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
      // Without cards — rows with "Unknown user".
    }
  }
  for (const id of unknown) {
    if (!out.has(`u${id}`)) out.set(`u${id}`, { id, title: 'Unknown user' });
  }
  chaseAvatars(out);
  return out;
}

// Avatars not yet on disk: users.cards and chats.avatars order them, while
// the rows are drawn already. Ask again a few times and put them into the
// same circles (peerLine remembers them by card).
const AVATAR_RETRY_MS = 1200;
const AVATAR_RETRIES = 4;
const circles = new WeakMap();   // card -> avatar circles

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

/** The default second line: a bot — "bot", a chat — its kind, a person — the status. */
function defaultSub(card) {
  if (card.bot || card.kind === 'bot') return 'bot';
  if (card.kind === 'group') return 'group';
  if (card.kind === 'channel') return 'channel';
  return card.status ? statusText(card) : '';
}

/** A row: avatar, name, a second line, on the right — a node (a button). */
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
 * A choice of chats from the list with checkboxes and search. kinds — which
 * kinds to show (user, bot, group, channel, self). .chosen() — ids as strings.
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

/** A chat's kind by id (for the rules: a person or a group). */
export const chatKind = (id) => chatById(id)?.kind ?? 'user';
