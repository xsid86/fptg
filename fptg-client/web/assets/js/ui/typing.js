import { on, emit } from '../core/bus.js';

// Кто сейчас печатает (или записывает, выбирает стикер…) — по событию
// typing сервера (webapi ChatAction, из updateChatAction TDLib). Шапка
// чата (ui/chat-header.js) показывает строку вместо подзаголовка.
//
// Гасит действие отмена TDLib (chatActionCancel) — она приходит на
// каждое. TTL — страховка на потерянную отмену (разрыв связи): TDLib
// повторяет действие, пока оно идёт, раз в несколько секунд, так что
// живое за это время продлится само.
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
    // chatActionCancel — и всё, чего страница не умеет назвать.
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
  // Без связи отмен не будет — показанное стало бы неправдой.
  on('net:status', (status) => { if (status !== 'open') clearAll(); });
}

/**
 * Строка для шапки или ''.
 *
 * opts.inThread — открыта ветка комментариев: в ней — только действия в
 * ветках этой группы (номер ветки TDLib — id копии поста в группе, а его
 * страница не знает); вне ветки — все действия чата.
 * opts.personal — личка: без имени, «typing…», как у официальных клиентов.
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
