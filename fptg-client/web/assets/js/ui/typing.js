import { on, emit } from '../core/bus.js';

// Who is typing now (or recording, choosing a sticker…) — by the server's
// typing event (webapi ChatAction, from TDLib's updateChatAction). The chat
// header (ui/chat-header.js) shows a line instead of the subtitle.
//
// An action is cancelled by TDLib's cancel (chatActionCancel) — it comes for
// each. The TTL is insurance against a lost cancel (a dropped connection):
// TDLib repeats an action while it lasts every few seconds, so a live one
// extends itself within that time.
const TTL_MS = 6000;

const LABEL = {
  chatActionTyping: 'typing',
  chatActionRecordingVoiceNote: 'recording a voice message',
  chatActionUploadingVoiceNote: 'sending a voice message',
  chatActionRecordingVideo: 'recording a video',
  chatActionRecordingVideoNote: 'recording a video message',
  chatActionUploadingVideo: 'sending a video',
  chatActionUploadingVideoNote: 'sending a video message',
  chatActionUploadingPhoto: 'sending a photo',
  chatActionUploadingDocument: 'sending a file',
  chatActionChoosingSticker: 'choosing a sticker',
  chatActionChoosingLocation: 'choosing a location',
  chatActionChoosingContact: 'choosing a contact',
  chatActionStartPlayingGame: 'playing a game',
  chatActionWatchingAnimations: 'watching an animation',
};

// chatId -> Map(senderId -> { name, action, threadId, timer })
const chats = new Map();

function drop(chatId, senderId) {
  const who = chats.get(chatId);
  const was = who?.get(senderId);
  if (!was) return;
  clearTimeout(was.timer);
  who.delete(senderId);
  if (!who.size) chats.delete(chatId);
  emit('ui:typing', chatId);
}

function onTyping(data) {
  const chatId = Number(data?.chatId);
  const senderId = Number(data?.senderId);
  if (!chatId || !senderId) return;
  if (!LABEL[data.action]) {
    // chatActionCancel — and everything the page cannot name.
    drop(chatId, senderId);
    return;
  }
  let who = chats.get(chatId);
  if (!who) {
    who = new Map();
    chats.set(chatId, who);
  }
  clearTimeout(who.get(senderId)?.timer);
  who.set(senderId, {
    name: data.name || 'Someone',
    action: data.action,
    threadId: Number(data.threadId) || 0,
    timer: setTimeout(() => drop(chatId, senderId), TTL_MS),
  });
  emit('ui:typing', chatId);
}

function clearAll() {
  const ids = [...chats.keys()];
  for (const who of chats.values()) {
    for (const w of who.values()) clearTimeout(w.timer);
  }
  chats.clear();
  for (const id of ids) emit('ui:typing', id);
}

let watching = false;

export function watchTyping() {
  if (watching) return;
  watching = true;
  on('srv:typing', onTyping);
  // Without a connection there will be no cancels — what is shown would become untrue.
  on('net:status', (status) => { if (status !== 'open') clearAll(); });
}

/**
 * The line for the header or ''.
 *
 * opts.inThread — a comment thread is open: in it — only actions in this
 * group's threads (TDLib's thread number is the id of the post's copy in
 * the group, and the page does not know it); outside a thread — all the
 * chat's actions.
 * opts.personal — a private chat: without a name, "typing…", as in the official clients.
 */
export function typingLine(chatId, opts = {}) {
  const who = chats.get(Number(chatId));
  if (!who) return '';
  const list = [...who.values()].filter((w) => !opts.inThread || w.threadId !== 0);
  if (!list.length) return '';
  const label = LABEL[list[0].action];
  if (opts.personal) return `${label}…`;
  if (list.length === 1) return `${list[0].name} is ${label}…`;
  if (list.length === 2) return `${list[0].name} and ${list[1].name} are ${label}…`;
  return `${list.length} people are ${label}…`;
}
