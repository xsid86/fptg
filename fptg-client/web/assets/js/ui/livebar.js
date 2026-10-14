import { el, clear } from '../core/dom.js';
import { emit, on } from '../core/bus.js';
import { store, onActiveChat, openThread } from '../core/store.js';
import { fillAvatar } from '../util/avatar.js';
import { icon } from '../util/icons.js';

// Плашка над историей, пока в открытом чате идёт видеочат или
// трансляция: что это (Live stream / Video chat), сколько участников,
// аватарки последних говоривших и «Join» (ui:vchat-join -> ui/videochat.js).
//
// Есть ли звонок — поле videoChat строки чата (webapi RowToJson, из
// chat.video_chat / updateChatVideoChat). Подробности — vchat.info один
// раз на звонок; дальше число участников обновляют события vchat
// (updateGroupCall, TDLib шлёт их после getGroupCall).

let bar = null;
let parts = null;
// Чат и звонок, для которых плашка заполнена; повторно не спрашивать —
// onActiveChat срабатывает на каждое обновление списка.
let shownChat = null;
let shownCall = 0;
let call = null;

function plural(n, one, many) {
  return `${n} ${n === 1 ? one : many}`;
}

function speakerNode(p) {
  const box = el('span', { class: `avatar avatar--sm live-bar__face accent-${p.color || 'a5'}` });
  fillAvatar(box, { title: p.name || '?', avatar: p.avatar || '', avatarThumb: p.avatarThumb || '' });
  return box;
}

function paint() {
  if (!bar) return;
  const chat = store.activeChat;
  const visible = Boolean(chat && call && call.active && !openThread());
  bar.hidden = !visible;
  if (!visible) return;
  // Цвет контакта для «цвета чата» (@include tint в _live-bar.scss).
  bar.className = `live-bar accent-${chat.color || 'a5'}`;
  const stream = call.rtmp || chat.kind === 'channel';
  parts.title.textContent = call.title || (stream ? 'Live stream' : 'Video chat');
  parts.count.textContent = plural(call.count ?? 0, 'participant', 'participants');
  // У трансляции (RTMP) говорящих нет — тогда аватарка самого канала,
  // как у официальных клиентов.
  let faces = call.speakers ?? [];
  if (!faces.length && stream) {
    faces = [{ name: chat.title, avatar: chat.avatar, avatarThumb: chat.avatarThumb, color: chat.color }];
  }
  clear(parts.faces).append(...faces.map(speakerNode));
}

async function load(chat) {
  const chatId = chat.id;
  const callId = chat.videoChat;
  try {
    const info = await emitCall('vchat.info', { chatId });
    // Пока ждали ответ, могли открыть другой чат.
    if (shownChat !== chatId || shownCall !== callId) return;
    call = info?.call ?? null;
  } catch {
    call = null;
  }
  paint();
}

let hooks = {};
const emitCall = (cmd, args) => hooks.call(cmd, args);

function onChat(chat) {
  const chatId = chat?.id ?? null;
  const callId = chat?.videoChat ?? 0;
  if (chatId !== shownChat || callId !== shownCall) {
    shownChat = chatId;
    shownCall = callId;
    call = null;
    if (chat && callId) load(chat);
  }
  paint();
}

export function mountLiveBar(header, options) {
  hooks = options ?? {};
  parts = {
    title: el('span', { class: 'live-bar__title' }),
    count: el('span', { class: 'live-bar__count' }),
    faces: el('span', { class: 'live-bar__faces' }),
    join: el('button', {
      class: 'btn btn--primary live-bar__join', type: 'button',
      onclick: () => emit('ui:vchat-join'),
    }, 'Join'),
  };
  bar = el('div', { class: 'live-bar', hidden: true },
    el('span', { class: 'live-bar__icon' }, icon('video', 'icon--sm')),
    el('span', { class: 'live-bar__text' }, parts.title, parts.count),
    parts.faces,
    parts.join);
  header.after(bar);

  onActiveChat(onChat);
  on('store:messages', () => paint());      // ветка комментариев открылась / закрылась
  on('srv:vchat', (c) => {
    if (!c || c.id !== shownCall) return;
    call = c;
    paint();
  });
}
