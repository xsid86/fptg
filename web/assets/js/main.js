import { qs } from './core/dom.js';
import { on, emit } from './core/bus.js';
import { connect, call } from './core/net.js';
import { store, setChats, setArchived, setActiveChat, setMessages, onActiveChat } from './core/store.js';
import { loadIcons, hydrateIcons } from './util/icons.js';
import { openMenu } from './util/menu.js';
import { mountChatList, showListLoading, showListError } from './ui/chat-list.js';
import { mountChatHeader } from './ui/chat-header.js';
import { mountHistory } from './ui/history.js';
import { mountComposer } from './ui/composer.js';
import { mountStatusBar } from './ui/status-bar.js';

// Entry point: wire the shell that index.html already contains, open
// the socket, and translate between what the UI asks for and what the
// protocol calls it. Nothing below main.js knows a command name.

const listNode = qs('#chat-list');

// chatFolderName allows 1..12 CHARACTERS (not bytes - a Cyrillic name
// is two bytes per character). Mirrors CHATROW_FOLDER_NAME_MAX; the
// server checks it too, this is only what the prompt says out loud.
const FOLDER_NAME_MAX = 12;

/**
 * Trailing throttle. The server's events are signals, not payloads, and
 * they fire as often as the model changes - which during a download is
 * many times a second. Refetching on every one of those would be work
 * nobody asked for; refetching on the last one of each burst is what
 * was actually wanted.
 */
function throttle(fn, ms) {
  let timer = null;
  let queued = false;
  return () => {
    if (timer) { queued = true; return; }
    fn();
    timer = setTimeout(() => {
      timer = null;
      if (queued) { queued = false; timer = setTimeout(() => { timer = null; fn(); }, 0); }
    }, ms);
  };
}

function report(err) {
  emit('ui:error', err instanceof Error ? err.message : String(err));
}

// --------------------------------------------------- folder menu
/**
 * The menu behind a row's folder chip: the account's folders with the
 * current one marked, then the two actions.
 *
 * The same shape as the native menu, including the deliberate bits:
 * "Remove from folder" is DISABLED rather than dropped when the chat is
 * in none, so the menu keeps the same shape wherever it opens and the
 * item the user is reaching for does not move from row to row. Folders
 * carry no icons because TDLib describes a folder's icon by name only -
 * see CmdChatsFolders in webapi.pas.
 */
async function showFolderMenu(id, anchor) {
  let folders;
  try {
    folders = await call('chats.folders');
  } catch (error) {
    report(error);
    return;
  }

  // Read the current folder off the row we already have rather than
  // asking again: 0 means "in no folder", the same convention the
  // server uses in both directions.
  const chat = store.chats.find((row) => row.id === id);
  const current = chat?.folderId ?? 0;

  const move = (folderId) => call('chat.folder.set', { id, folderId }).catch(report);

  const items = folders.map((folder) => ({
    label: folder.title,
    checked: folder.id === current,
    onSelect: () => move(folder.id),
  }));
  if (items.length) items.push('-');

  items.push({
    label: 'Remove from folder',
    disabled: current === 0,
    onSelect: () => move(0),
  });
  items.push({
    label: 'New folder',
    // prompt() rather than a dialog of our own: this is the one place
    // in the app that needs a line of text back, and the native window
    // asks with InputQuery for the same reason. The server checks the
    // length too - this is a courtesy, not the guard.
    onSelect: () => {
      const title = prompt(`New folder name (up to ${FOLDER_NAME_MAX} characters):`, '');
      if (title === null) return;
      call('chat.folder.create', { id, title }).catch(report);
    },
  });

  openMenu(anchor, items);
}

// --------------------------------------------------------- fetching
async function loadChats() {
  try {
    const result = await call('chats.list', { archived: store.archived });
    setChats(result.items);
    // Avatars only for what is on screen, the way the native list does
    // it - asking for a hundred downloads because the app started is
    // exactly what it avoids.
    const ids = result.items.slice(0, 40).map((c) => c.id);
    if (ids.length) call('chats.avatars', { ids }).catch(() => {});
  } catch (err) {
    setChats([]);
    showListError(listNode, `Could not load chats: ${err.message}`);
  }
}

async function loadMessages() {
  if (store.activeChatId === null) return;
  try {
    setMessages(await call('messages.list'));
  } catch (err) {
    report(err);
  }
}

const refreshChats = throttle(loadChats, 400);
const refreshMessages = throttle(loadMessages, 150);

// ---------------------------------------------------------- actions
function wireActions() {
  // Opening a chat is a real state change on the SHARED model - it
  // tells TDLib which chat is on screen and reloads the history, which
  // the native window sees too. So it hangs off 'store:active' alone,
  // the event that fires only when the user really picked another chat.
  on('store:active', async (chat) => {
    if (!chat) return;
    try {
      setMessages(await call('chat.open', { id: chat.id }));
    } catch (err) {
      report(err);
    }
  });

  on('ui:send', async (payload) => {
    try {
      await call('message.send', payload);
      await loadMessages();
    } catch (err) {
      report(err);
    }
  });

  on('ui:load-older', throttle(() => {
    call('messages.older').catch(report);
  }, 300));

  on('ui:mark-read', (ids) => {
    call('messages.read', { ids }).catch(() => {});
  });

  on('ui:ensure-media', (args) => {
    call('media.ensure', args).catch(() => {});
  });

  on('ui:vote', (args) => {
    call('poll.vote', args).catch(report);
  });

  // Clicking a photo opens the ORIGINAL, not the medium layer that is
  // shown inline - the same split the native viewer makes. When the
  // original is not downloaded yet the click asks for it and the image
  // opens on the next one, which is the native "two clicks" rule
  // rather than a surprise download-then-open.
  on('ui:view', ({ msg }) => {
    const full = msg.media?.fullUrl;
    if (full) window.open(full, '_blank', 'noopener');
    else call('media.ensure', { id: msg.id, what: 'full' }).catch(report);
  });

  on('ui:jump', (messageId) => {
    call('chat.open', { id: store.activeChatId, jumpTo: messageId })
      .then(setMessages).catch(report);
  });

  on('ui:open-source', ({ chatId, messageId }) => {
    // Following a forward to its source is a chat switch, so the list
    // selection has to move with it or the header would name one chat
    // while the history shows another.
    setActiveChat(chatId);
    call('chat.open', { id: chatId, jumpTo: messageId })
      .then(setMessages).catch(report);
  });

  on('ui:chat-action', ({ id, action }) => {
    call('chat.action', { id, action }).catch(report);
  });

  on('ui:folder-menu', ({ id, anchor }) => showFolderMenu(id, anchor));

  on('ui:search', ({ filter, query }) => {
    call('search.set', { filter, query }).then(setMessages).catch(report);
  });
}

function wireSidebar() {
  qs('#chats-refresh').addEventListener('click', loadChats);

  qs('#chats-archived').addEventListener('change', (event) => {
    setArchived(event.target.checked);
  });
  on('store:archived', loadChats);

  // Filtering the loaded list in the page rather than asking the server
  // again: it is already here, and a round trip per keystroke would be
  // both slower and noisier than a scan of a few hundred items.
  qs('#chats-search').addEventListener('input', (event) => {
    const needle = event.target.value.trim().toLowerCase();
    for (const node of listNode.children) {
      const chat = store.chats.find((c) => String(c.id) === node.dataset.chatId);
      const hit = !needle
        || (chat?.title ?? '').toLowerCase().includes(needle)
        || (chat?.preview ?? '').toLowerCase().includes(needle);
      node.hidden = !hit;
    }
  });
}

function wireResponsive() {
  const app = qs('.app');
  onActiveChat((chat) => {
    app.dataset.view = chat ? 'chat' : 'list';
  });
  document.addEventListener('click', (event) => {
    if (event.target.closest('.chat-header__back')) app.dataset.view = 'list';
  });
}

async function boot() {
  await loadIcons();
  hydrateIcons();

  mountChatList(listNode);
  mountChatHeader(qs('#chat-header'));
  mountHistory(qs('#history'));
  mountComposer(qs('#composer'));
  mountStatusBar(qs('#status-bar'));

  wireSidebar();
  wireResponsive();
  wireActions();

  // The server pushes signals, never data: "the list changed", "the
  // open chat changed". What to fetch, and how often, is the page's
  // decision - see throttle above.
  on('srv:chats', refreshChats);
  on('srv:messages', refreshMessages);

  // Load on every (re)connect, not just the first: after a drop the
  // list on screen is however stale the disconnection left it.
  on('net:status', (status) => {
    if (status !== 'open') return;
    loadChats();
    if (store.activeChatId !== null) loadMessages();
  });

  connect();
}

boot().catch((err) => {
  console.error(err);
  document.body.textContent = `Failed to start: ${err.message}`;
});
