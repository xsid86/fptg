import { emit } from './bus.js';

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
  // message, the unread count going to zero). Anything watching the
  // active chat wants to know.
  if (data.activeChatId !== null) emit('store:active', store.activeChat);
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

export function setMessages(payload) {
  data.messages = payload;
  emit('store:messages', payload);
}
