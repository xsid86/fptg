import { emit } from './bus.js';

// All shared state in one place, changed only through these functions.
// Small enough not to need anything cleverer, and having a single owner
// means "who changed this" is never a question.

const data = {
  chats: [],
  archived: false,
  activeChatId: null,
};

export const store = {
  get chats() { return data.chats; },
  get archived() { return data.archived; },
  get activeChatId() { return data.activeChatId; },
  get activeChat() { return data.chats.find((c) => c.id === data.activeChatId) ?? null; },
};

export function setChats(chats) {
  data.chats = chats;
  emit('store:chats', chats);
}

export function setArchived(flag) {
  if (data.archived === flag) return;
  data.archived = flag;
  emit('store:archived', flag);
}

export function setActiveChat(id) {
  if (data.activeChatId === id) return;
  data.activeChatId = id;
  emit('store:active', store.activeChat);
}
