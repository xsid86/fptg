import { el } from '../core/dom.js';
import { emit, on } from '../core/bus.js';
import { store, onActiveChat, openThread } from '../core/store.js';
import { icon, kindIcon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { watchTyping, typingLine } from './typing.js';

// The bar above the history: identity on the left, the search field and
// the filter strip on the right.
//
// Mirrors chatheader.pas, including the rules that are not a UI
// preference but the API's shape:
//
//   * AT MOST ONE filter at a time - searchChatMessages takes exactly
//     one SearchMessagesFilter, so several at once would mean running
//     several searches and merging them by hand;
//   * clicking the active one turns it off, and "off" with an empty box
//     is how the bar asks for the ordinary history back;
//   * filter and query COMBINE rather than replace each other, because
//     the request itself takes both: "photos" plus a word narrows to
//     photos whose caption matches.
//
// Two of the eleven toggles are stubs, and not because they were
// forgotten: TDLib answers gifts with receivedGifts and saved with a
// savedMessagesTopic history, and neither of those is a list of
// messages. An empty filter constructor is what marks them, here as in
// the native header, and such a toggle can never become the active one.
//
// THE BAR IS BUILT ONCE AND UPDATED IN PLACE. onActiveChat also fires
// on every chat-list refresh (store:active-row), and rebuilding the
// nodes would throw away what the user is typing - and the focus with
// it - every time an unread count changed.

// Icon, label, and the SearchMessagesFilter constructor it stands for
// ('' for the two that cannot be one). The names are TD_MSG_FILTER_* in
// constants.pas; they travel as strings because the server takes the
// constructor name straight through to the request.
const FILTERS = [
  // Photos, videos, GIFs, music, links, voice messages, files and pinned —
  // not a history filter but a grid or a
  // list in the info panel, as in the native client (ui/infopanel.js,
  // media.list): far more fits on one screen, and a click on a tile scrolls
  // the full history to the message.
  ['image', 'Photos', '@photo'],
  ['video', 'Videos', '@video'],
  ['gif', 'GIFs', '@gif'],
  ['audio', 'Music', '@audio'],
  ['mic', 'Voice messages', '@voice'],
  ['file', 'Files', '@file'],
  ['link', 'Links', '@link'],
  ['poll', 'Polls', 'searchMessagesFilterPoll'],
  ['pin', 'Pinned', '@pinned'],
  // Not a history filter: TDLib has no searchMessagesFilter for gifts — the
  // button opens the profile's gifts in the info panel (ui/infopanel.js).
  ['gift', 'Gifts', '@gifts'],
  ['bookmark', 'Saved', ''],
];

const STUB_NOTE = 'answered by TDLib with something that is not a list of messages';

let root = null;
let parts = null;
let activeFilter = '';
// The Saved Messages source whose messages are shown (ui/infopanel.js):
// { id, title } or null — a chip with a cross in the filter strip.
let savedTopic = null;
// What the media grid in the info panel shows ('photo' | 'video' | ''):
// its button in the strip is highlighted while the grid is open.
let mediaView = '';
let lastChatId = null;
// What the bar last drew for the thread - title, picture, colour and
// comment count rolled into one string. Empty means "no thread".
let threadMark = '';

function apply() {
  emit('ui:search', { filter: activeFilter, query: parts.input.value.trim(), savedTopic: savedTopic?.id ?? 0 });
}

function syncTopic() {
  parts.topic.hidden = !savedTopic;
  parts.topicLabel.textContent = savedTopic?.title ?? '';
}

function toggleFilter(type) {
  if (!type) return;
  if (type === '@gifts') {
    emit('ui:open-gifts');
    return;
  }
  if (['@photo', '@video', '@gif', '@audio', '@link', '@voice', '@file', '@pinned'].includes(type)) {
    emit('ui:open-media', type.slice(1));
    return;
  }
  activeFilter = activeFilter === type ? '' : type;
  syncFilters();
  apply();
}

function syncFilters() {
  for (const { type, node } of parts.filters) {
    node.classList.toggle('is-active', Boolean(type)
      && (type === activeFilter || type === `@${mediaView || '-'}`));
  }
}

function onSearchKey(e) {
  if (e.key === 'Enter') {
    // Applied on Enter rather than on every keystroke: each apply is a
    // real request to Telegram, and the native field does the same.
    e.preventDefault();
    apply();
    return;
  }
  if (e.key === 'Escape') {
    // Clears and re-runs, which drops back to the plain history when no
    // filter is on either. Swallowed so it does not travel on to
    // anything that treats Escape as "close" - the picture viewer does.
    e.preventDefault();
    e.stopPropagation();
    parts.input.value = '';
    apply();
  }
}

function build() {
  // A click — the other side's avatar gallery; for a group and channel —
  // the info panel (ui/infopanel.js, ui:chat-photos).
  const avatar = el('span', {
    class: 'avatar avatar--lg chat-header__avatar',
    role: 'button', tabindex: '0', title: 'Photos',
    // anchor — the loading ring is hung on it while the gallery downloads.
    onclick: (event) => emit('ui:chat-photos', { anchor: event.currentTarget }),
    onkeydown: (event) => {
      if (event.key === 'Enter') emit('ui:chat-photos', { anchor: event.currentTarget });
    },
  });
  // One button, two jobs: on a narrow screen it goes back to the chat
  // list (the .app[data-view] switch in main.js), and in a comment
  // thread it leaves the thread. Hidden on a wide screen unless a
  // thread is open - see render().
  const back = el('button', {
    class: 'btn btn--icon chat-header__back',
    type: 'button',
    title: 'Back',
    hidden: true,
    onclick: (event) => {
      if (!openThread()) return;      // narrow screen: back to the list
      // Leaving the thread is the whole action here, so the
      // document-level "back to the list" handler must not also fire.
      event.stopPropagation();
      emit('ui:thread-close');
    },
  }, icon('chevron-left'));
  const titleIcon = icon('chat', 'icon--sm');
  const titleText = el('span', { class: 'u-ellipsis' });
  const subtitle = el('div', { class: 'chat-header__subtitle' });

  const input = el('input', {
    class: 'field__input',
    type: 'search',
    placeholder: 'Search...',
    autocomplete: 'off',
    title: 'Enter to search, Escape to clear',
    onkeydown: onSearchKey,
  });
  const count = el('span', { class: 'chat-header__count', hidden: true });

  const topicLabel = el('span', { class: 'chat-header__topic-label' });
  const topic = el('button', {
    class: 'chip chat-header__topic', type: 'button', hidden: true, title: 'Show all saved messages',
    onclick: () => {
      savedTopic = null;
      syncTopic();
      apply();
    },
  }, icon('bookmark', 'icon--sm'), topicLabel, icon('close', 'icon--sm'));
  const strip = el('div', { class: 'chat-header__filters' });
  const filters = FILTERS.map(([name, label, type]) => {
    const node = el('button', {
      class: 'chat-filter',
      type: 'button',
      title: type ? label : `${label} - ${STUB_NOTE}`,
      disabled: !type,
      onclick: () => toggleFilter(type),
    }, icon(name, 'icon--sm'), el('span', { class: 'u-sr-only', textContent: label }));
    strip.append(node);
    return { type, node };
  });

  root.append(
    back,
    avatar,
    el('div', { class: 'chat-header__identity' },
      el('div', { class: 'chat-header__title' }, titleIcon, titleText),
      subtitle),
    el('div', { class: 'chat-header__tools' },
      topic,
      el('label', { class: 'field chat-header__search' },
        icon('search', 'icon--sm'), input, count),
      strip),
  );

  parts = { avatar, back, titleIcon, titleText, subtitle, input, count, filters, topic, topicLabel };
}

/** "no comments yet" / "1 comment" / "N comments". */
function commentLabel(n) {
  if (!n) return 'no comments yet';
  return n === 1 ? '1 comment' : `${n} comments`;
}

// The subtitle without "typing": the header returns to it when everyone
// has gone quiet.
let baseSubtitle = '';

// A private chat — "typing…" without a name: there is only one other side.
const PERSONAL = ['private', 'bot', 'secret', 'self'];

/**
 * The subtitle: "someone is typing" while that is so, otherwise the usual one.
 *
 * The actions' chat is the one whose history is open (store.messages.chatId):
 * in a comment thread that is the discussion group, not the channel in the header.
 */
function paintSubtitle() {
  if (!parts) return;
  const chat = store.activeChat;
  const chatId = store.messages?.chatId ?? chat?.id;
  const line = chat
    ? typingLine(chatId, { inThread: !!openThread(), personal: PERSONAL.includes(chat.kind) })
    : '';
  parts.subtitle.textContent = line || baseSubtitle;
  parts.subtitle.classList.toggle('is-typing', !!line);
}

function render(chat) {
  if (!root) return;
  if (!chat) {
    // Drop the previous chat's accent class too, so a hidden header
    // cannot come back wearing the wrong colour.
    root.className = 'chat-header';
    root.hidden = true;
    lastChatId = null;
    return;
  }

  if (chat.id !== lastChatId) {
    lastChatId = chat.id;
    // Opening another chat clears the model's filter (TTdMessages.Clear
    // does), so the bar must not go on showing one. Nothing is sent:
    // the model has already done it.
    activeFilter = '';
    savedTopic = null;
    parts.input.value = '';
    parts.count.hidden = true;
    syncFilters();
    syncTopic();
  }

  root.hidden = false;
  // Reading a post's comments: the bar says so and offers the way out,
  // because the chat underneath is still the channel and nothing else
  // on screen would explain where these messages came from.
  const thread = openThread();
  root.classList.toggle('chat-header--thread', !!thread);
  // On a narrow screen this is still "back to the chat list"; in a
  // thread on a wide one the way out is the floating button over the
  // history instead, so the bar keeps only its own job.
  parts.back.hidden = !thread;
  // Same palette class the list row carries, so the header and the row
  // for one chat can never disagree about its colour.
  // In a thread the header is still the channel (the user's decision,
  // 2026-10-10): people read the comments on ITS post, and the discussion
  // group's avatar confused. The group — in the subtitle, if its name differs.
  const face = chat;
  root.className = `chat-header accent-${face.color ?? chat.color}`;
  // The same picture the row in the list shows - see util/avatar.js.
  fillAvatar(parts.avatar, face);
  const kind = icon(kindIcon(chat.kind), 'icon--sm');
  parts.titleIcon.replaceWith(kind);
  parts.titleIcon = kind;
  parts.titleText.textContent = face.title || '(no title)';
  // What this thread is: how many comments, and in which group.
  baseSubtitle = thread
    ? [commentLabel(thread.post?.comments ?? 0),
       thread.title !== face.title ? thread.title : '']
        .filter(Boolean).join(' \u00b7 ')
    : subtitle(chat);
  paintSubtitle();
}

/**
 * The search state comes back from the server, so the bar follows it
 * rather than only its own clicks - the native window drives the SAME
 * model, and a filter switched on over there has to show here too.
 *
 * The one thing not taken back is the text while it is being typed:
 * overwriting the box under the caret would be hostile.
 */
function syncFromState(state) {
  if (!parts || !state) return;

  // Everything the bar shows in a thread lives in THIS payload, not in
  // the chat - so it has to redraw from here too. Without it, leaving
  // a thread left the discussion group's name and picture on screen
  // until some unrelated chat-list refresh happened to nudge it.
  //
  // Compared as a whole rather than as "is there a thread": the
  // group's picture is asked for when the thread opens and arrives a
  // payload or two later, so the bar that drew a letter has to notice
  // and draw the photo.
  const mark = state.thread
    ? [state.thread.title, state.thread.avatar, state.thread.color,
       state.thread.post?.comments].join('|')
    : '';
  if (mark !== threadMark) {
    threadMark = mark;
    render(store.activeChat);
  }

  activeFilter = state.searchFilter ?? '';
  syncFilters();
  if (!state.savedTopic && savedTopic) {
    savedTopic = null;
    syncTopic();
  }

  const query = state.searchQuery ?? '';
  if (document.activeElement !== parts.input && parts.input.value !== query) {
    parts.input.value = query;
  }

  const active = Boolean(state.searchActive);
  parts.count.hidden = !active;
  if (active) parts.count.textContent = `${state.searchTotal ?? 0} found`;
}

function subtitle(chat) {
  const parts = [chat.kind];
  if (chat.folder) parts.push(chat.folder);
  if (chat.unread > 0) parts.push(`${chat.unread} unread`);
  return parts.join(' · ');
}

export function mountChatHeader(node) {
  root = node;
  build();
  onActiveChat(render);
  on('store:messages', syncFromState);
  watchTyping();
  on('ui:typing', (chatId) => {
    const open = store.messages?.chatId ?? store.activeChatId;
    if (Number(chatId) === Number(open)) paintSubtitle();
  });
  // A click on a media counter in the info panel (ui/infopanel.js) — the
  // same filter as the button in the filter strip.
  // A Saved Messages source from the info panel — the history of it only.
  on('ui:saved-topic', ({ id, title }) => {
    savedTopic = { id, title };
    syncTopic();
    apply();
  });
  on('ui:set-filter', (type) => {
    activeFilter = type;
    syncFilters();
    apply();
  });
  on('info:media-view', (filter) => {
    mediaView = filter;
    // The grid scrolls the full history — a history filter would get in its
    // way (wherever the grid was opened from: a button here or a counter in the panel).
    if (filter && activeFilter) {
      activeFilter = '';
      apply();
    }
    syncFilters();
  });
  render(null);
}
