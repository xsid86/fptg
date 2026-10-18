import { el, clear } from '../core/dom.js';
import { emit, on } from '../core/bus.js';
import { store, onActiveChat, openThread } from '../core/store.js';
import { fillAvatar } from '../util/avatar.js';
import { icon } from '../util/icons.js';

// A plate above the history while a video chat or a live stream is on in
// the open chat: what it is (Live stream / Video chat), how many
// participants, the avatars of the last speakers and "Join" (ui:vchat-join
// -> ui/videochat.js).
//
// Whether there is a call — the videoChat field of the chat row (webapi
// RowToJson, from chat.video_chat / updateChatVideoChat). The details —
// vchat.info once per call; after that the vchat events update the
// participant count (updateGroupCall, TDLib sends them after getGroupCall).

let bar = null;
let parts = null;
// The chat and call the plate is filled for; do not ask again — onActiveChat
// fires on every list update.
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
  // The contact's colour for the "chat colour" (@include tint in _live-bar.scss).
  bar.className = `live-bar accent-${chat.color || 'a5'}`;
  const stream = call.rtmp || chat.kind === 'channel';
  parts.title.textContent = call.title || (stream ? 'Live stream' : 'Video chat');
  parts.count.textContent = plural(call.count ?? 0, 'participant', 'participants');
  // A stream (RTMP) has no speakers — then the channel's own avatar, as in
  // the official clients.
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
    // While we waited for the answer, another chat may have been opened.
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
  on('store:messages', () => paint());      // a comment thread opened / closed
  on('srv:vchat', (c) => {
    if (!c || c.id !== shownCall) return;
    call = c;
    paint();
  });
}
