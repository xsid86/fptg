import { emit, on } from './bus.js';

// All shared state in one place, changed only through these functions.
// Small enough not to need anything cleverer, and having a single owner
// means "who changed this" is never a question.

const data = {
  chats: [],
  archived: false,
  activeChatId: null,
  messages: null,
};

export const store = {
  get chats() { return data.chats; },
  get archived() { return data.archived; },
  get activeChatId() { return data.activeChatId; },
  get activeChat() { return data.chats.find((c) => c.id === data.activeChatId) ?? null; },
  get messages() { return data.messages; },
};

export function setChats(chats) {
  data.chats = chats;
  emit('store:chats', chats);
  // The open chat's own row may have changed with the list (a new last
  // message, the unread count going to zero, a rename), and the header
  // and the composer want to know.
  //
  // This is deliberately NOT 'store:active'. Saying both with one event
  // was a real bug: the handler that opens a chat on the server fired
  // on every list refresh, and since the native window shares this
  // model, its history jumped to whatever chat this page had open while
  // its own selection stayed behind. Redraw-only listeners take both
  // events through onActiveChat.
  if (data.activeChatId !== null) emit('store:active-row', store.activeChat);
}

export function setArchived(flag) {
  if (data.archived === flag) return;
  data.archived = flag;
  emit('store:archived', flag);
}

export function setActiveChat(id) {
  if (data.activeChatId === id) return;
  data.activeChatId = id;
  // The history belongs to the previous chat until the server answers
  // with the new one; dropping it here stops the old messages being on
  // screen under the new title for a frame.
  data.messages = null;
  emit('store:active', store.activeChat);
}

/**
 * For anything that only REDRAWS when the active chat changes or when
 * its row data is refreshed. Anything with a side effect - opening the
 * chat on the server, resetting the scroll position - must subscribe to
 * 'store:active' itself, because that one fires only on a real switch.
 */
export function onActiveChat(handler) {
  on('store:active', handler);
  on('store:active-row', handler);
}

export function setMessages(payload) {
  data.messages = payload;
  emit('store:messages', payload);
}
