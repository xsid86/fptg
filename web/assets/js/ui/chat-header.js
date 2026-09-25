import { el } from '../core/dom.js';
import { emit, on } from '../core/bus.js';
import { onActiveChat } from '../core/store.js';
import { icon, kindIcon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';

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
  ['image', 'Photos', 'searchMessagesFilterPhoto'],
  ['video', 'Videos', 'searchMessagesFilterVideo'],
  ['gif', 'GIFs', 'searchMessagesFilterAnimation'],
  ['audio', 'Music', 'searchMessagesFilterAudio'],
  ['mic', 'Voice messages', 'searchMessagesFilterVoiceNote'],
  ['file', 'Files', 'searchMessagesFilterDocument'],
  ['link', 'Links', 'searchMessagesFilterUrl'],
  ['poll', 'Polls', 'searchMessagesFilterPoll'],
  ['pin', 'Pinned', 'searchMessagesFilterPinned'],
  ['gift', 'Gifts', ''],
  ['bookmark', 'Saved', ''],
];

const STUB_NOTE = 'answered by TDLib with something that is not a list of messages';

let root = null;
let parts = null;
let activeFilter = '';
let lastChatId = null;

function apply() {
  emit('ui:search', { filter: activeFilter, query: parts.input.value.trim() });
}

function toggleFilter(type) {
  if (!type) return;
  activeFilter = activeFilter === type ? '' : type;
  syncFilters();
  apply();
}

function syncFilters() {
  for (const { type, node } of parts.filters) {
    node.classList.toggle('is-active', Boolean(type) && type === activeFilter);
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
  const avatar = el('span', { class: 'avatar avatar--lg chat-header__avatar' });
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
    el('button', { class: 'btn btn--icon chat-header__back', type: 'button', title: 'Back' },
      icon('chevron-left')),
    avatar,
    el('div', { class: 'chat-header__identity' },
      el('div', { class: 'chat-header__title' }, titleIcon, titleText),
      subtitle),
    el('div', { class: 'chat-header__tools' },
      el('label', { class: 'field chat-header__search' },
        icon('search', 'icon--sm'), input, count),
      strip),
  );

  parts = { avatar, titleIcon, titleText, subtitle, input, count, filters };
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
    parts.input.value = '';
    parts.count.hidden = true;
    syncFilters();
  }

  root.hidden = false;
  // Same palette class the list row carries, so the header and the row
  // for one chat can never disagree about its colour.
  root.className = `chat-header accent-${chat.color}`;
  // The same picture the row in the list shows - see util/avatar.js.
  fillAvatar(parts.avatar, chat);
  const kind = icon(kindIcon(chat.kind), 'icon--sm');
  parts.titleIcon.replaceWith(kind);
  parts.titleIcon = kind;
  parts.titleText.textContent = chat.title || '(no title)';
  parts.subtitle.textContent = subtitle(chat);
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

  activeFilter = state.searchFilter ?? '';
  syncFilters();

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
  render(null);
}
