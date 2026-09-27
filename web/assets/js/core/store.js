import { emit, on } from './bus.js';

// All shared state in one place, changed only through these functions.
// Small enough not to need anything cleverer, and having a single owner
// means "who changed this" is never a question.

const data = {
  chats: [],
  archived: false,
  activeChatId: null,
  // The open chat's ROW, kept apart from the list on screen.
  //
  // It used to be looked up in `chats` on demand, and that made the
  // open chat vanish whenever its row was not in the list being shown
  // - switching to the archive with an ordinary chat open, most
  // obviously. Every refresh of that list then announced "no chat" to
  // everything that redraws, so the history wiped itself, the composer
  // went dead, and the next messages refresh put it all back: a
  // flicker, once per list refresh, plus a burst of "load older" on
  // the emptied history (measured: 72 getChatHistory in three
  // minutes).
  //
  // A chat does not stop being open because you are looking somewhere
  // else. This holds the last row seen for it.
  activeRow: null,
  messages: null,
};

export const store = {
  get chats() { return data.chats; },
  get archived() { return data.archived; },
  get activeChatId() { return data.activeChatId; },
  get activeChat() { return data.activeRow; },
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
  if (data.activeChatId === null) return;
  // Only ever replaced by a row that is really there. A list without
  // it says nothing about the chat - see data.activeRow.
  const row = chats.find((c) => c.id === data.activeChatId);
  if (row) data.activeRow = row;
  emit('store:active-row', data.activeRow);
}

export function setArchived(flag) {
  if (data.archived === flag) return;
  data.archived = flag;
  emit('store:archived', flag);
}

export function setActiveChat(id) {
  if (data.activeChatId === id) return;
  data.activeChatId = id;
  data.activeRow = data.chats.find((c) => c.id === id) ?? null;
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
  // The open chat may have no row in the list and never grow one: a
  // channel this account does not follow, arrived at by following a
  // forward or a quote. The row the server sends with the history is
  // then the only one there is, and without it the header and the
  // composer would draw "no chat" over a screenful of messages.
  const row = payload?.chat;
  if (row && row.id === data.activeChatId && data.activeRow?.id !== row.id) {
    data.activeRow = row;
    emit('store:active-row', data.activeRow);
  }
  emit('store:messages', payload);
}

/**
 * The comment thread currently open, or null.
 *
 * It rides along with the message list rather than being its own piece
 * of state, because it changes at exactly the same moments and for
 * exactly the same reason. The chat that is open while a thread is
 * being read is the DISCUSSION group, which may not be in the chat
 * list at all - so the header and the composer ask here instead of
 * reading a row that does not exist.
 */
export function openThread() {
  return data.messages?.thread ?? null;
}
