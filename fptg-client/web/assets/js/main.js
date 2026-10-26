import { qs, el } from './core/dom.js';
import { on, emit } from './core/bus.js';
import { connect, call } from './core/net.js';
import { store, setChats, setArchived, setActiveChat, setMessages, activeOffList } from './core/store.js';
import { setCustomEmoji } from './util/emoji.js';
import { applyRoot } from './util/prefs.js';
import { loadIcons, hydrateIcons } from './util/icons.js';
import { openMenu } from './util/menu.js';
import {
  mountChatList, showListLoading, showListError, setChatFilter,
  showContacts, hideContacts, setArchiveInfo,
} from './ui/chat-list.js';
import { mountChatHeader } from './ui/chat-header.js';
import { mountHistory, invalidateHistory } from './ui/history.js';
import {
  mountComposer, insertAtCaret, insertCustomEmoji, isSilent, replyTo, editMessage,
  htmlMode, canCompose, takeReply, customEmojiMarkup, richAttach,
} from './ui/composer.js';
import { mountMessageMenu, openMessageMenu, toggleReaction } from './ui/msgmenu.js';
import { mountSearch } from './ui/search.js';
import { mountNewChat, newGroup, newChannel } from './ui/newchat.js';
import { mountMainMenu } from './ui/mainmenu.js';
import { mountRecorder, cancelRecording } from './ui/recorder.js';
import { mountPayments } from './ui/payments.js';
import { mountTranslate } from './ui/translate.js';
import { mountCalls } from './ui/call.js';
import { setCanTranscribe } from './ui/message.js';
import { mountVideoChat } from './ui/videochat.js';
import { mountLiveBar } from './ui/livebar.js';
import { mountLiveStream } from './ui/livestream.js';
import { mountStories } from './ui/stories.js';
import { mountPicker, pickerChanged } from './ui/picker.js';
import { mountAuth, showAuth } from './ui/auth.js';
import { mountStatusBar } from './ui/status-bar.js';
import { mountToasts } from './ui/toasts.js';
import { mountShell } from './ui/shell.js';
import { mountSounds } from './util/sounds.js';
import { mountThemeToggle } from './ui/theme.js';
import { mountSettings, openSettings, openSettingsList } from './ui/settings.js';
import { mountAttach } from './ui/attach.js';
import { mountPeople } from './ui/people.js';
import { mountLinks, openLink } from './ui/links.js';
import { mountBots, redrawBotKeyboard } from './ui/bots.js';
import { mountAttachMenu } from './ui/attachmenu.js';
import { mountGreeting } from './ui/greeting.js';
import { mountSponsored } from './ui/sponsored.js';
import { mountInfoPanel, addContactDialog } from './ui/infopanel.js';
import { setMapFetcher, setMapProvider, setMapSaver } from './util/maps.js';
import { mountSoloPlay } from './util/soloplay.js';
import { mountNotices, notice } from './ui/notices.js';
import { openViewer } from './ui/viewer.js';

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
async function showFolderMenu(id, anchor, contact = null) {
  let folders;
  try {
    folders = await call('chats.folders');
  } catch (error) {
    report(error);
    return;
  }

  // Read the current folder off the row we already have rather than
  // asking again: 0 means "in no folder", the same convention the
  // server uses in both directions. A contact's row brings its own -
  // its private chat need not be in the list on screen at all.
  const chat = store.chats.find((row) => row.id === id);
  const current = contact ? contact.current : (chat?.folderId ?? 0);

  // After moving from a contact row the contact list is re-read.
  // (A contact without a conversation gets no buttons at all — chat-list.js.)
  const done = () => { if (contact) emit('ui:contacts-stale'); };
  const move = (folderId) => call('chat.folder.set', { id, folderId })
    .then(done)
    .catch(report);

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
      call('chat.folder.create', { id, title })
        .then(done)
        .catch(report);
    },
  });

  openMenu(anchor, items);
}

// --------------------------------------------------------- fetching
/**
 * Every list response carries a dictionary of the custom emoji its
 * rows mention. It is registered before the rows are handed on, so
 * that whatever renders them next can already look them up.
 */
// The post whose comments are open. Carried by the page rather than
// fetched again: the click that opens a thread happens ON that
// message, so the page already holds it - and the thread has to show
// it at the top, or there is nothing to quote a line of the post from.
let threadPost = null;
// The message a pending chat switch is being made for - see
// ui:open-source.
let pendingJump = 0;

function applyMessages(state) {
  // NOT cleared when a payload arrives without a thread. thread.open
  // answers with the list as it stands, and at that moment TDLib has
  // only been ASKED what the thread is - the first payload back still
  // describes the channel. Clearing here threw the post away a beat
  // before the thread it belongs to arrived. It is cleared where it
  // really ends instead: leaving the thread, or opening a chat.
  if (state?.thread) state.thread.post = threadPost;
  const fresh = setCustomEmoji(state?.customEmoji);
  // The voice transcription button — Premium only (ui/message.js).
  // History nodes are cached by message content — when the flag changes
  // (Premium bought) redraw the voice messages already drawn.
  if (state && 'canTranscribe' in state && setCanTranscribe(state.canTranscribe)) invalidateHistory();
  setMessages(state);
  // A custom emoji's file arriving changes no message, so the history's
  // per-payload node cache cannot see it. Told explicitly, it redraws.
  if (fresh) {
    invalidateHistory();
    redrawBotKeyboard();
  }
}

/**
 * Which step of signing in the application is on, and therefore
 * whether there is anything else to show at all.
 *
 * The chat list is only asked for once the answer is "ready". Asking
 * earlier is not merely wasteful - before an account exists every
 * command answers "no active account", and the page would open on an
 * error it has no business reporting.
 */
let signedIn = false;

async function refreshAuth() {
  const info = await call('auth.state');
  showAuth(info);
  const ready = info?.state === 'ready';
  if (ready === signedIn) return;
  signedIn = ready;
  if (ready) await loadChats();
}

async function loadChats() {
  try {
    const result = await call('chats.list', { archived: store.archived });
    setCustomEmoji(result.customEmoji);
    setArchiveInfo(result.archive);
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
    // The difference, not the whole history. The server answers in
    // full anyway whenever it cannot tell what this page already has.
    applyMessages(await call('messages.list', { delta: true }));
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
  on('store:active', async () => {
    // A chat of one's own is not a thread; whatever post was being
    // commented on is behind us.
    threadPost = null;
    // Set by ui:open-source just before it switched chats: the message
    // this opening is FOR. Taken here so it cannot outlive its errand.
    const jumpTo = pendingJump;
    pendingJump = 0;
    // The ID, not the row. A chat reached by following a forward or a
    // quote can be one the account does not follow, and then there is
    // no row in the list to find - but the chat is just as open, and
    // bailing out here left the reader looking at the chat they came
    // from with nothing loaded. The row arrives with the history
    // instead (see setMessages).
    const id = store.activeChatId;
    if (!id) return;
    // The header shows this chat's picture, and the list only asks for
    // the first screenful of them - so a chat opened from further down
    // would sit under an initial for as long as it stayed open. The
    // URL rides back in the next chats.list, like every other avatar.
    call('chats.avatars', { ids: [id] }).catch(() => {});
    try {
      applyMessages(await call('chat.open',
        jumpTo ? { id, jumpTo } : { id }));
      // A standing wish, retried after every render: the message is
      // not on the page yet at this point (see ui/history.js).
      if (jumpTo) emit('ui:show-message', jumpTo);
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

  // A rich message — the blocks are already assembled by the input field (util/richcompose.js).
  on('ui:send-rich', async (payload) => {
    try {
      await call('message.sendRich', payload);
      await loadMessages();
    } catch (err) {
      report(err);
    }
  });

  // Stickers and GIFs are sent, not typed: the panel hands over a file
  // id and the server turns it into inputMessageSticker/Animation.
  // A voice message or a round video — recorded and uploaded (ui/recorder.js).
  on('ui:send-note', async (payload) => {
    try {
      await call('message.sendNote', payload);
      await loadMessages();
    } catch (err) {
      report(err);
    }
  });

  on('ui:send-media', async (payload) => {
    try {
      await call('message.sendMedia', { ...payload, silent: isSilent() });
      await loadMessages();
    } catch (err) {
      report(err);
    }
  });

  // Rewriting a message is its own command, not a send with a flag:
  // editMessageText answers with the message rather than creating one,
  // and the two paths diverge from the parse onwards.
  on('ui:edit', async (payload) => {
    try {
      await call('message.edit', payload);
      await loadMessages();
    } catch (err) {
      report(err);
    }
  });

  on('ui:message-menu', ({ msg, anchor, at }) => {
    openMessageMenu(anchor, msg, at).catch(report);
  });

  on('ui:react', ({ msg, emoji }) => toggleReaction(msg, emoji));

  on('ui:trim-history', () => {
    // Answers with the history, shorter - applied like any other
    // change to it.
    call('messages.trim').then(applyMessages).catch(report);
  });

  on('ui:load-older', throttle(() => {
    call('messages.older').catch(report);
  }, 300));

  // A history detached from the newest end (a jump into the past):
  // newer pages at the bottom, and "down" back to the newest.
  on('ui:load-newer', throttle(() => {
    call('messages.newer').catch(report);
  }, 300));

  on('ui:latest', () => {
    call('messages.latest').then(applyMessages).catch(report);
  });

  on('ui:mark-read', (ids) => {
    call('messages.read', { ids }).catch(() => {});
  });

  on('ui:ensure-media', (args) => {
    call('media.ensure', args).catch(() => {});
  });

  on('ui:cancel-transfer', (args) => {
    call('message.cancelTransfer', args).catch(report);
  });

  // Avatars of rows that came into the list's view (ui/chat-list.js). The
  // addresses themselves arrive with the next chats.list, as before.
  on('ui:avatars', (ids) => {
    call('chats.avatars', { ids }).catch(() => {});
  });

  on('ui:vote', (args) => {
    call('poll.vote', args).catch(report);
  });

  // Clicking a photo opens the ORIGINAL, not the medium layer that is
  // shown inline - the same split the native viewer makes. When the
  // original is not downloaded yet the click asks for it and the image
  // opens on the next one, which is the native "two clicks" rule
  // rather than a surprise download-then-open.
  on('ui:view', ({ msg, group }) => {
    // An album opens as a gallery on the picture that was clicked; a
    // lone photo is a gallery of one.
    const list = group?.length ? group : [msg];
    const start = Math.max(0, list.indexOf(msg));
    openViewer(list, start);

    // The viewer shows whatever was already to hand, which for a photo
    // that has not been downloaded is the inline preview. Asking for the
    // originals here means the next open is sharp - and it is the only
    // thing that ever requests them, since nothing else needs the full
    // file.
    for (const m of list) {
      if (m.kind === 'photo' && !m.media?.fullUrl) {
        call('media.ensure', { id: m.id, what: 'full' }).catch(report);
      }
    }
  });

  // Following a quote, or a forward back to its source. Both are the
  // same errand - put that message on screen - and it is worth having
  // one way to run it, because the two halves are easy to get wrong
  // separately: landing in the right chat without moving the view, or
  // moving the view in the wrong chat.
  on('ui:open-source', ({ chatId, messageId }) => {
    if (!messageId) return;
    // A quote in a comment thread points to a message of the discussion
    // group — the chat open in the model (messages.chatId), not the channel
    // the page considers open. The jump is inside the thread; switching to
    // the group would leave the thread for its general feed.
    const held = store.messages;
    if (held?.thread && chatId === held.chatId) {
      call('thread.jump', { messageId: String(messageId) })
        .then(applyMessages)
        .then(() => emit('ui:show-message', messageId))
        .catch(report);
      return;
    }
    if (chatId && chatId !== store.activeChatId) {
      // The jump rides WITH the opening request rather than following
      // it. A chat opened at its newest end first would put unread
      // messages on screen, and what is on screen is marked read - so
      // a glance at an old quote would eat the unread count of a
      // channel the reader follows.
      pendingJump = messageId;
      setActiveChat(chatId);
      return;
    }
    call('chat.open', { id: store.activeChatId, jumpTo: messageId })
      .then(applyMessages)
      .then(() => emit('ui:show-message', messageId))
      .catch(report);
  });

  // The date chip in the history: the server finds the day's first message,
  // then an ordinary jump to the message.
  on('ui:jump-date', (date) => {
    const chatId = store.activeChatId;
    if (!chatId || !date) return;
    call('chat.dateJump', { id: chatId, date })
      .then((r) => {
        if (r?.messageId && store.activeChatId === chatId) {
          emit('ui:open-source', { chatId, messageId: r.messageId });
        }
      })
      .catch(report);
  });

  on('ui:chat-action', ({ id, action }) => {
    call('chat.action', { id, action }).catch(report);
  });

  on('ui:transcribe', ({ id }) => call('message.transcribe', { id }).catch(report));
  on('ui:folder-menu', ({ id, anchor, userId, current }) =>
    showFolderMenu(id, anchor, userId ? { current: current ?? 0 } : null));

  // The comments pill under a channel post, and the way back out.
  on('ui:comments', ({ msg }) => {
    threadPost = msg;
    call('thread.open', { id: msg.id }).then(applyMessages).catch(report);
  });
  on('ui:join-chat', () => {
    // No id: the server joins the chat the history is in, which in a
    // thread is the discussion group.
    call('chat.join').then(() => loadMessages()).catch(report);
  });
  on('ui:thread-close', () => {
    const postId = threadPost?.id ?? null;
    threadPost = null;
    call('thread.close').then((state) => {
      applyMessages(state);
      // The history has just been rebuilt around that post; now put it
      // where the reader can see it.
      if (postId !== null) emit('ui:show-message', postId);
    }).catch(report);
  });

  on('ui:search', ({ filter, query, savedTopic }) => {
    call('search.set', { filter, query, savedTopic: savedTopic ?? 0 }).then(applyMessages).catch(report);
  });
}

// Contacts instead of chats (the Contacts button). The list is asked when
// turned on and refreshed together with the chat list — not more often than
// once per CONTACTS_REFRESH_MS: downloaded avatars and "online" statuses
// arrive only with a new request (contacts.list — getUser for each).
const CONTACTS_REFRESH_MS = 5000;
// Avatars still downloading (photoPending): the list is re-requested with
// this pause while there are such, but no more than CONTACTS_PHOTO_TRIES
// times per turning on (a live log: 46 files downloaded in under 40 s).
const CONTACTS_PHOTO_RETRY_MS = 2000;
const CONTACTS_PHOTO_TRIES = 20;
const CONTACTS_STALE_MS = 3000;
let contactsAsked = 0;
let contactsStaleUntil = 0;
let contactsTries = 0;
let contactsTimer = 0;
// Whether the contacts mode is on (the button is not a toggle: its label
// says where it leads).
let contactsOn = false;

function loadContacts() {
  contactsAsked = Date.now();
  clearTimeout(contactsTimer);
  call('contacts.list')
    .then((r) => {
      if (!contactsOn) return;
      const list = r?.contacts ?? [];
      showContacts(list);
      if (list.some((c) => c.photoPending) && contactsTries < CONTACTS_PHOTO_TRIES) {
        contactsTries += 1;
        contactsTimer = setTimeout(() => { if (contactsOn) loadContacts(); }, CONTACTS_PHOTO_RETRY_MS);
      }
    })
    .catch(report);
}

function setContactsMode(on) {
  contactsOn = on;
  contactsTries = 0;
  clearTimeout(contactsTimer);
  if (on) loadContacts();
  else hideContacts();
}

/**
 * What the list on the left shows: 'chats', 'archive' or 'contacts'. The
 * archive is reached by its row at the top of the chats, contacts from the
 * menu (ui/mainmenu.js), and both go back by the first row (ui/chat-list.js).
 */
let listView = 'chats';
// The list's name in its header, between the menu and "+".
const LIST_TITLES = { chats: 'Chats', archive: 'Archive', contacts: 'Contacts' };
let listTitle = null;

function setSidebarView(view) {
  listView = view;
  if (listTitle) listTitle.textContent = LIST_TITLES[view] ?? '';
  // Another tab — search and the contact filter end.
  const box = qs('#chats-search');
  if (box.value) {
    box.value = '';
    setChatFilter('');
  }
  emit('ui:search-close');
  if (view === 'contacts') {
    if (store.archived) setArchived(false);
    if (!contactsOn) setContactsMode(true);
    return;
  }
  if (contactsOn) setContactsMode(false);
  const archived = view === 'archive';
  if (store.archived !== archived) setArchived(archived);
}

// A phone: in the archive or the contacts a swipe to the right goes back to
// the chats, as the back gesture of the mobile apps (the tabs it used to
// switch between are gone). Only a clearly sideways gesture counts — a
// vertical one is the list scrolling — and only on the narrow layout (the
// phone width of scss/layout/_phone.scss).
const SWIPE_MIN_PX = 60;
const SWIPE_RATIO = 1.5;
const SWIPE_MAX_MS = 600;
const PHONE_QUERY = '(max-width: 640px)';

function wireSwipeTabs(area) {
  const phone = window.matchMedia(PHONE_QUERY);
  let start = null;
  area.addEventListener('touchstart', (event) => {
    start = phone.matches && event.touches.length === 1
      ? { x: event.touches[0].clientX, y: event.touches[0].clientY, t: Date.now() }
      : null;
  }, { passive: true });
  area.addEventListener('touchend', (event) => {
    if (!start) return;
    const touch = event.changedTouches[0];
    const dx = touch.clientX - start.x;
    const dy = touch.clientY - start.y;
    const quick = Date.now() - start.t <= SWIPE_MAX_MS;
    start = null;
    if (!quick || Math.abs(dx) < SWIPE_MIN_PX || Math.abs(dx) < Math.abs(dy) * SWIPE_RATIO) return;
    if (dx > 0 && listView !== 'chats') setSidebarView('chats');
  }, { passive: true });
  area.addEventListener('touchcancel', () => { start = null; }, { passive: true });
}

function wireSidebar() {
  // The archive row and the "back to chats" row (ui/chat-list.js).
  on('ui:list-view', (view) => setSidebarView(view));
  wireSwipeTabs(qs('.sidebar__body'));
  on('srv:chats', () => {
    if (!contactsOn) return;
    const now = Date.now();
    if (now < contactsStaleUntil || now - contactsAsked > CONTACTS_REFRESH_MS) loadContacts();
  });
  // A contact's folder was changed from its row: TDLib sends the chat's new
  // positions in several updates (remove from the old folders, add to the
  // new one), so for CONTACTS_STALE_MS the list is re-read on each, without
  // the usual pause — otherwise the chip would show an intermediate state.
  on('ui:contacts-stale', () => {
    contactsStaleUntil = Date.now() + CONTACTS_STALE_MS;
    if (contactsOn) loadContacts();
  });
  // A click on a contact: the private chat with them (createPrivateChat —
  // bot.userChat), the list returns to chats.
  on('ui:open-contact', ({ userId }) => {
    call('bot.userChat', { userId })
      .then((r) => {
        setSidebarView('chats');
        if (r?.chatId) setActiveChat(r.chatId);
      })
      .catch(report);
  });
  on('store:archived', loadChats);

  // The field above the list: in Chats and Archive — search, as in Telegram
  // Desktop (ui/search.js); in Contacts — a filter of the loaded contacts,
  // they are all here already (setChatFilter).
  mountSearch(qs('#chats-search'), qs('.sidebar'), qs('.sidebar__body'), {
    disabled: () => contactsOn,
  });
  // Voice messages and round videos — the button to the right of the input
  // field (ui/recorder.js); another chat — an unfinished recording is lost.
  mountRecorder(qs('#composer'), { canCompose, takeReply, isSilent, report });
  on('store:active', cancelRecording);
  // "+" to the right of the tabs: a new group or channel (ui/newchat.js).
  mountNewChat(qs('.sidebar__head'), { call: (cmd, args) => call(cmd, args) });
  // The menu at the left of the header (ui/mainmenu.js); what its items do.
  mountMainMenu(qs('.sidebar__head'), {
    account: async () => {
      const list = await call('accounts.list');
      return list?.accounts?.find((a) => a.index === list.active) ?? null;
    },
    profile: () => openSettings('account'),
    newGroup,
    newChannel,
    contacts: () => setSidebarView('contacts'),
    // Saved messages: the account's own chat — from the list, or opened as
    // the private chat with oneself.
    saved: async () => {
      const self = store.chats.find((c) => c.kind === 'self');
      if (self) {
        setSidebarView('chats');
        setActiveChat(self.id);
        return;
      }
      const list = await call('accounts.list').catch(() => null);
      const me = list?.accounts?.find((a) => a.index === list.active);
      if (me?.userId) emit('ui:open-contact', { userId: me.userId });
    },
    settings: openSettingsList,
  });
  listTitle = el('div', { class: 'sidebar__title', textContent: LIST_TITLES[listView] });
  qs('.sidebar__menu')?.after(listTitle);
  qs('#chats-search').addEventListener('input', (event) => {
    if (contactsOn) setChatFilter(event.target.value);
  });
}

function wireResponsive() {
  const app = qs('.app');
  // Only a real switch (store:active), not every refresh of the open
  // chat's row (onActiveChat): a list tab re-reads the chats, the active
  // row comes again, and the narrow window jumped from the list to the
  // last chat. By the id: a chat off the list has no row at the switch.
  on('store:active', () => {
    app.dataset.view = store.activeChatId !== null ? 'chat' : 'list';
  });
  // The same chat tapped again after Back: nothing switches, the view does.
  on('ui:chat-shown', () => {
    if (store.activeChatId !== null) app.dataset.view = 'chat';
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
  mountLiveBar(qs('#chat-header'), { call: (cmd, args) => call(cmd, args) });
  mountHistory(qs('#history'));
  mountComposer(qs('#composer'));
  // The menu reads and acts through main.js like every other view:
  // ui/ modules own the DOM, this file owns the socket.
  mountMessageMenu({
    load: (cmd, args) => call(cmd, args),
    act: (cmd, args) => call(cmd, args).then(loadMessages).catch(report),
    reply: replyTo,
    edit: editMessage,
    report,
    notice,
  });
  mountAuth(qs('#auth'), {
    send: (cmd, args) => call(cmd, args)
      // The refusal for a step is part of the step: the server reports
      // it with the next auth state, so there is nothing to show here
      // beyond the ones that never get that far.
      .then(() => refreshAuth())
      .catch(report),
  });
  mountPicker(qs('#composer-emoji'), {
    insert: insertAtCaret,
    insertCustom: insertCustomEmoji,
    send: (payload) => emit('ui:send-media', payload),
    load: (cmd, args) => call(cmd, args),
  });
  mountStatusBar(qs('#status-bar'));
  mountToasts(qs('#toasts'));
  // The fptg window around the page: desktop cards, mini apps, the tray
  // (ui/shell.js). A click on a card and links from a mini app come from
  // there too.
  mountShell({ call: (cmd, args) => call(cmd, args), openLink, report });
  mountSounds();
  // This window's interface scale and animations (Chat settings, Battery
  // and animation) — root classes, before the first windows.
  applyRoot();
  mountThemeToggle(qs('#theme-toggle'));
  mountSettings(qs('#settings'), null, {
    load: (cmd, args) => call(cmd, args),
    report,
  });
  mountPeople({ load: (args) => call('message.people', args) });
  mountNotices(qs('#notices'));
  mountBots(qs('#composer'), {
    call: (cmd, args) => call(cmd, args),
    report,
    notice,
    openChat: (id) => setActiveChat(id),
    // The bot keyboard button and a command from the menu — an ordinary
    // message on one's own behalf. HTML, not MarkdownV2: the button text
    // must not turn into markup because of an asterisk.
    send: (text) => emit('ui:send', { text, html: true, silent: isSilent(), replyTo: '' }),
    silent: isSilent,
    // replyMarkupForceReply: the input field replies to this message at once.
    replyTo,
  });
  // Map pictures for locations in the history (util/maps.js): one arrived —
  // the history is redrawn, as when a custom emoji arrives.
  setMapFetcher((lat, lon) => call('map.thumb', { lat, lon }).then((r) => r?.url));
  on('ui:map-ready', () => invalidateHistory());
  // The default map service (Settings → Location service) — the "Remember
  // my choice" checkbox in the choice window saves it too.
  setMapSaver((id) => call('settings.set', { key: 'maps.provider', value: id }).catch(report));
  on('srv:settings', (data) => setMapProvider(data?.mapsProvider ?? ''));
  mountGreeting({ call: (cmd, args) => call(cmd, args), report });
  // Official Telegram ads in channels and chats with bots (ui/sponsored.js).
  mountSponsored(qs('#composer'), { call: (cmd, args) => call(cmd, args), report, notice });
  // The chat info panel — the "i" button in the corner of the history.
  mountInfoPanel(qs('.workspace__history'), { call: (cmd, args) => call(cmd, args), report, notice });
  // Translating the chat's messages — the button under "i" (ui/translate.js).
  mountTranslate(qs('.workspace__history'), { report });
  // Paying invoices: the "Buy" buttons and t.me/$name links (ui:pay-invoice).
  mountPayments({ call: (cmd, args) => call(cmd, args), report, notice });
  // Calls: the call window and WebRTC (ui/call.js, calls/*.js); start — ui:call-start.
  mountCalls({ call: (cmd, args) => call(cmd, args), report, notice });
  // Video chats of groups and channels (ui/videochat.js, calls/group.js); open — ui:vchat-open.
  mountVideoChat({ call: (cmd, args) => call(cmd, args), report, notice });
  mountLiveStream({ call: (cmd, args) => call(cmd, args), report, notice });
  mountStories({ call: (cmd, args) => call(cmd, args), report, notice });
  // "Add contact" on a contact card in the history — the same window as in the panel.
  on('ui:add-contact', (args) => { addContactDialog(args); });
  mountAttachMenu(qs('#composer'), {
    call: (cmd, args) => call(cmd, args),
    report,
    canCompose,
  });
  mountLinks({
    call: (cmd, args) => call(cmd, args),
    openChat: (id) => setActiveChat(id),
    // The same path as following a forward: the chat opens right at the
    // needed message.
    openMessage: (chatId, messageId) => emit('ui:open-source', { chatId, messageId }),
    report,
    notice,
  });
  mountAttach(qs('#attach'), qs('#dropzone'), qs('.workspace'), {
    call: (cmd, args) => call(cmd, args),
    canCompose,
    htmlMode,
    isSilent,
    takeReply,
    customEmojiMarkup,
    richAttach,
  });

  wireSidebar();
  wireResponsive();
  // One playback with sound at a time (util/soloplay.js).
  mountSoloPlay();
  wireActions();

  // The server pushes signals, never data: "the list changed", "the
  // open chat changed". What to fetch, and how often, is the page's
  // decision - see throttle above.
  on('srv:chats', () => {
    refreshChats();
    // The open chat is not in the list — its row (and the avatar downloaded
    // just now) arrives only with the history, not with the list. A diff
    // messages.list is cheap.
    if (activeOffList()) refreshMessages();
  });
  on('srv:messages', refreshMessages);
  on('srv:auth', () => { refreshAuth().catch(report); });
  // Not throttled here: the server already coalesces this one to a tick,
  // and the panel ignores it unless it is open on the tab concerned.
  on('srv:stickers', pickerChanged);

  // Load on every (re)connect, not just the first: after a drop the
  // list on screen is however stale the disconnection left it.
  //
  // Signing in is asked about FIRST, and the chat list only follows
  // from its answer - see refreshAuth. A reconnect can land on a
  // different step than the last one did (the application may have
  // been signed out while the page was away).
  on('net:status', (status) => {
    if (status !== 'open') return;
    signedIn = false;
    refreshAuth().catch(report);
    call('settings.get').then((data) => setMapProvider(data?.mapsProvider ?? '')).catch(() => {});
    if (store.activeChatId !== null) loadMessages();
  });

  connect();
}

boot().catch((err) => {
  console.error(err);
  document.body.textContent = `Failed to start: ${err.message}`;
});
