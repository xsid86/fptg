import { qs } from './core/dom.js';
import { on } from './core/bus.js';
import { connect, call, state as netState } from './core/net.js';
import { store, setChats, setArchived } from './core/store.js';
import { loadIcons, hydrateIcons } from './util/icons.js';
import { mountChatList, showListLoading, showListError } from './ui/chat-list.js';
import { mountChatHeader } from './ui/chat-header.js';
import { mountHistory } from './ui/history.js';
import { mountComposer } from './ui/composer.js';
import { mountStatusBar } from './ui/status-bar.js';

// Entry point: wire the shell that index.html already contains, open
// the socket, and fetch what there is to fetch. Nothing here knows the
// protocol beyond the command names - that belongs to core/net.js.

const listNode = qs('#chat-list');

async function loadChats() {
  showListLoading(listNode);
  try {
    const result = await call('chats.list', { archived: store.archived });
    setChats(result.items);
  } catch (err) {
    setChats([]);
    showListError(listNode, `Could not load chats: ${err.message}`);
  }
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
  on('store:active', (chat) => {
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

  // Load on every (re)connect, not just the first: after a drop the
  // list on screen is however stale the disconnection left it.
  on('net:status', (status) => {
    if (status === 'open') loadChats();
  });

  connect();
}

boot().catch((err) => {
  console.error(err);
  document.body.textContent = `Failed to start: ${err.message}`;
});
