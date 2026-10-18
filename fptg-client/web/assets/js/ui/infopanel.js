import { el, clear } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { copyText } from '../util/clipboard.js';
import { openMenu, reanchorMenu } from '../util/menu.js';
import { openViewer } from './viewer.js';
import { formDialog, field, pickChats } from './bots.js';
import { statusText } from './chat-list.js';
import { stickerNode } from './message.js';
import { duration, listTime, initial, fileSize, dateLabel } from '../util/format.js';
import { updateFloatDate } from '../util/floatdate.js';
import { userIdNode } from './userid.js';
import { openManage } from './manage.js';

// The chat info panel — a person, a bot, a group or a channel. It opens
// with the "i" button in the top right corner of the history and slides in
// from the right over it (unlike the official client — at the user's
// request).
//
// What is inside follows the native client: the avatar (for people — a
// gallery of their photos), name and status, the Chat / Mute / Call / More
// buttons, phone, bio, username, birthday, the group's description and
// link, media counters (as a grid or a list right here), gifts, group
// members and actions: share the contact, add / edit / delete the contact,
// block, leave the group.
//
// Data — the bridge: chat.info, chat.members, info.action (webapi.pas).

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'];

// Media counters: the key from chat.info, the label and the history filter
// (the same as the buttons in the chat header — FILTERS in
// ui/chat-header.js). '@kind' is not a filter but a grid or a list right
// here, in the panel (openMedia).
const COUNTS = [
  ['photo', 'image', 'photos', '@photo'],
  ['video', 'video', 'videos', '@video'],
  ['document', 'file', 'files', '@file'],
  ['audio', 'audio', 'audio files', '@audio'],
  ['url', 'link', 'links', '@link'],
  ['voice', 'mic', 'voice messages', '@voice'],
  ['animation', 'gif', 'GIFs', '@gif'],
  ['poll', 'poll', 'polls', '@poll'],
];

let hooks = {};
let toggle = null;
let panel = null;
let body = null;
let open = false;
let info = null;       // the latest chat.info answer
let loadingFor = null; // the chat a request is running for
let asked = 0;         // the request number: a stale answer is discarded

function setOpen(on) {
  open = on;
  if (!on) setView('info');
  panel.classList.toggle('is-open', on);
  toggle.classList.toggle('is-active', on);
  toggle.setAttribute('aria-expanded', String(on));
  if (on) load();
}

// The chat whose info is shown if it is NOT the open chat: "Contact info"
// from the message menu (ui:contact-info) — the private chat with the
// sender. Reset when the open chat changes.
let override = null;
const viewChatId = () => override ?? store.activeChatId;

/** Show the info of another chat without opening it (ui:contact-info). */
function openInfoFor(chatId) {
  override = chatId;
  setView('info');
  if (open) load();
  else setOpen(true);
}

async function load() {
  const chatId = viewChatId();
  if (!open || chatId === null) return;
  const my = ++asked;
  loadingFor = chatId;
  if (!info || info.chatId !== chatId) {
    clear(body).append(el('p', { class: 'info-panel__hint' }, 'Loading…'));
  }
  try {
    const next = await hooks.call('chat.info', { chatId });
    if (my !== asked) return;
    // Another chat — the previous one's gifts and media are of no use (a
    // grid already opened for this chat by the header button stays).
    if (info && info.chatId !== chatId && !(view === 'media' && media.chatId === chatId)) setView('info');
    // The bridge calls a private chat 'private' (and 'secret' — a secret
    // chat), like the chat list (ChatKindStr); for the panel it is one kind
    // — a person. Without this contacts had neither actions nor the More
    // menu.
    if (next.kind === 'private' || next.kind === 'secret') next.kind = 'user';
    // A background re-read (srv:chats — a message in ANY chat) most often
    // changes nothing: then do not redraw either — a redraw reset the
    // scroll and reloaded the members.
    const same = info && info.chatId === next.chatId;
    if (same && view === 'info' && JSON.stringify(next) === JSON.stringify(info)) return;
    info = next;
    // On gifts and media a background info update does not rebuild the
    // grid: it does not depend on them, and a rebuild restarted the
    // stickers and made it impossible to inspect the elements.
    if (view !== 'info') return;
    // The same chat — the reader stays where they scrolled to.
    const top = same ? body.scrollTop : 0;
    render();
    body.scrollTop = top;
  } catch (error) {
    if (my === asked) {
      clear(body).append(el('p', { class: 'info-panel__hint' }, 'No information available.'));
    }
    hooks.report(error);
  } finally {
    if (my === asked) loadingFor = null;
  }
}

// ---------------------------------------------------------- helpers
function statusLine(i) {
  switch (i.kind) {
    case 'self': return 'Saved Messages';
    case 'bot': return 'bot';
    case 'channel': return i.memberCount ? `${i.memberCount} subscribers` : 'channel';
    case 'group': return i.memberCount ? `${i.memberCount} members` : 'group';
    default: return i.status ? statusText(i) : '';
  }
}

function birthday(b) {
  if (!b) return '';
  return `${b.day} ${MONTHS[b.month - 1] ?? ''}${b.year ? ` ${b.year}` : ''}`;
}

/**
 * The Telegram ID under the name: a person's user id, a group's or
 * channel's chat id (-100…, as bots see it). A click — to the clipboard.
 */
function idLine(i) {
  const id = String(i.userId || i.chatId || '');
  if (!id) return null;
  return el('button', {
    class: 'info-panel__id', type: 'button', title: 'Copy ID',
    onclick: async () => {
      await copyText(id);
      hooks.notice('ID copied to clipboard');
    },
  }, `ID: ${id}`);
}

/** An info row: the value large, the label small; a click copies. */
function infoRow(value, label, copy) {
  return el('button', {
    class: 'info-panel__row', type: 'button', title: copy ? 'Copy' : '',
    onclick: async () => {
      if (!copy) return;
      await copyText(copy);
      hooks.notice('Copied to clipboard');
    },
  },
  el('span', { class: 'info-panel__value' }, value),
  el('span', { class: 'info-panel__label' }, label));
}

function actionButton(iconName, label, run) {
  return el('button', { class: 'info-panel__action', type: 'button', onclick: run },
    icon(iconName), el('span', {}, label));
}

async function act(args, done) {
  try {
    await hooks.call('info.action', args);
    if (done) hooks.notice(done);
  } catch (error) {
    hooks.report(error);
  }
  load();
}

async function confirmAct(text, ok, args, done) {
  if (!(await formDialog({ text, ok }))) return;
  await act(args, done);
}

// ---------------------------------------------------------- actions
async function shareContact(i) {
  const picked = await pickChats({
    title: 'Share contact', candidates: store.chats.filter((c) => c.id !== i.chatId), max: 1,
  });
  if (!picked?.length) return;
  await act({
    action: 'contact.share', userId: i.userId, toChatId: String(picked[0].id),
    phone: i.phone ?? '', first: i.firstName ?? i.title, last: i.lastName ?? '',
  }, 'Contact shared');
}

/** "Add contact" from a contact card in the history (ui:add-contact, main.js). */
export function addContactDialog({ userId, first, last }) {
  return editContact({ userId, firstName: first ?? '', lastName: last ?? '', isContact: false });
}

async function editContact(i) {
  const first = field({ type: 'text', placeholder: 'First name', value: i.firstName ?? '', maxLength: 64 });
  const last = field({ type: 'text', placeholder: 'Last name', value: i.lastName ?? '', maxLength: 64 });
  const yes = await formDialog({
    text: i.isContact ? 'Edit contact' : 'Add to contacts',
    body: [first, last],
    ok: i.isContact ? 'Save' : 'Add',
    check: () => (first.value.trim() ? '' : 'Enter a first name'),
  });
  if (!yes) return;
  await act({ action: 'contact.add', userId: i.userId, first: first.value, last: last.value },
    i.isContact ? 'Contact saved' : 'Contact added');
}

/** Actions by chat kind — both at the bottom of the panel and in the "More" menu. */
function actions(i) {
  const list = [];
  // Owner or administrator — management, like "Manage" in Desktop.
  if ((i.kind === 'group' || i.kind === 'channel') && i.canManage) {
    list.push([i.kind === 'channel' ? 'Manage channel' : 'Manage group',
      () => openManage(i.chatId, { call: hooks.call })]);
  }
  if (i.kind === 'user') {
    list.push(['Share contact', () => shareContact(i)]);
    list.push([i.isContact ? 'Edit contact' : 'Add to contacts', () => editContact(i)]);
    if (i.isContact) {
      list.push(['Delete contact', () => confirmAct(`Delete ${i.title} from contacts?`, 'Delete',
        { action: 'contact.remove', userId: i.userId }, 'Contact deleted')]);
    }
  }
  if (i.kind === 'bot' && i.username) {
    list.push(['Copy bot link', async () => {
      await copyText(`https://t.me/${i.username}`);
      hooks.notice('Copied to clipboard');
    }]);
  }
  if ((i.kind === 'group' || i.kind === 'channel') && (i.link || i.inviteLink)) {
    list.push(['Copy link', async () => {
      await copyText(i.link || i.inviteLink);
      hooks.notice('Copied to clipboard');
    }]);
  }
  if (i.kind === 'user' || i.kind === 'bot') {
    const what = i.kind === 'bot' ? 'Stop and block bot' : 'Block user';
    list.push([i.isBlocked ? 'Unblock' : what, () => (i.isBlocked
      ? act({ action: 'user.block', userId: i.userId, block: false }, 'Unblocked')
      : confirmAct(`Block ${i.title}?`, 'Block',
        { action: 'user.block', userId: i.userId, block: true }, 'Blocked')), true]);
  }
  if ((i.kind === 'group' || i.kind === 'channel') && i.isMember === false) {
    // Not a member — join (the chat is open: chat.join takes the open one).
    if (i.chatId === store.activeChatId) {
      list.push([i.kind === 'channel' ? 'Join channel' : 'Join group', () => emit('ui:join-chat')]);
    }
  } else if (i.kind === 'group' || i.kind === 'channel') {
    const what = i.kind === 'channel' ? 'Leave channel' : 'Leave group';
    list.push([what, () => confirmAct(`${what}?`, 'Leave',
      { action: 'chat.leave', chatId: String(i.chatId) }, 'Left'), true]);
  }
  return list;
}

// host — the avatar that was clicked: account.photos waits for all the
// photos to download (seconds on a long history), and all that time a ring
// spins around it (.is-ring-loading, components/_spinner.scss). A repeated
// click while the ring spins does not send a second request.
async function openPhotos(i, host = null) {
  if (!i.userId) return;
  if (host?.classList.contains('is-ring-loading')) return;
  host?.classList.add('is-ring-loading');
  try {
    const r = await hooks.call('account.photos', { userId: i.userId });
    host?.classList.remove('is-ring-loading');
    const photos = (r.photos ?? []).filter((p) => p.url && p.url !== '-');
    if (!photos.length) return;
    openViewer(photos.map((p) => (p.animUrl && p.animUrl !== '-'
      ? { id: p.id, kind: 'animation',
        media: { url: p.animUrl, thumbUrl: p.url, thumb: p.url, w: p.animSize || p.w, h: p.animSize || p.h } }
      : { id: p.id, kind: 'photo',
        media: { fullUrl: p.url, url: p.url, thumb: p.thumb, w: p.w, h: p.h, fullW: p.w, fullH: p.h } })), 0);
  } catch (error) {
    hooks.report(error);
  } finally {
    host?.classList.remove('is-ring-loading');
  }
}

// The member list drawn last (see render).
let membersShown = { chatId: null, nodes: [] };

async function loadMembers(box, i) {
  try {
    const r = await hooks.call('chat.members', { chatId: i.chatId });
    if (!info || info.chatId !== i.chatId) return;
    const members = (r.members ?? []).sort((a, b) => {
      const rank = (m) => (m.role === 'owner' ? 0 : m.role === 'admin' ? 1 : 2);
      return rank(a) - rank(b) || (a.title || '').localeCompare(b.title || '');
    });
    const nodes = members.map((m) => {
      const avatar = el('span', { class: `avatar avatar--sm accent-${m.color}` });
      fillAvatar(avatar, { id: m.userId, title: m.title, avatar: m.avatar, avatarThumb: m.avatarThumb });
      return el('button', {
        class: 'info-panel__member', type: 'button',
        onclick: () => emit('ui:open-contact', { userId: m.userId }),
      },
      avatar,
      el('span', { class: 'info-panel__member-text' },
        el('span', { class: 'info-panel__member-name' }, m.title || m.username || '(no name)'),
        userIdNode(m.userId),
        el('span', { class: 'info-panel__label' }, statusText(m))),
      // On the right as a column: on top, the label the member chose
      // themselves (an admin title or a tag, chatMember.tag) — as a chip
      // of their colour; below, the actual role.
      (m.tag || m.role)
        ? el('span', { class: 'info-panel__roles' },
          m.tag ? el('span', { class: `info-panel__tag accent-${m.color}` }, m.tag) : null,
          m.role ? el('span', { class: 'info-panel__role' }, m.role) : null)
        : null);
    });
    clear(box).append(...nodes);
    membersShown = { chatId: i.chatId, nodes };
  } catch (error) {
    clear(box);
    hooks.report(error);
  }
}

// ------------------------------------------------------ Saved Messages sources
// As in Telegram Desktop: the Saved Messages info lists the chats messages
// were saved from (savedMessagesTopic), with the last message; a click
// shows the history of that source only (search.set savedTopic, the header
// shows it as a chip). TDLib gives no method for topics —
// loadSavedMessagesTopics and updates the server keeps (td.kept
// "updateSavedMessagesTopic:").
//
// Between redraws of the panel the DATA is kept and the rows are built
// anew: ready nodes lying outside the document lose their pictures —
// util/offscreen.js releases them and forgets them on its sweep, and the
// avatar stayed a blurred placeholder forever.
const SAVED_REFRESH_MS = 10000;
const TOPIC_AVATAR_RETRY_MS = 1500;
const TOPIC_AVATAR_RETRIES = 6;
let saved = { at: 0, items: null, count: 0 };   // items: [{ id, name, type, row, last }]

function topicPreview(m) {
  const c = m?.content;
  if (!c) return '';
  const text = c.text?.text ?? c.caption?.text ?? '';
  const kind = {
    messagePhoto: 'Photo', messageVideo: 'Video', messageDocument: 'File', messageAudio: 'Audio',
    messageVoiceNote: 'Voice message', messageVideoNote: 'Video message', messageSticker: 'Sticker',
    messageAnimation: 'GIF', messagePoll: 'Poll', messageLocation: 'Location', messageContact: 'Contact',
  }[c['@type']];
  if (kind && text) return `${kind}, ${text}`;
  return text || kind || '';
}

function topicNodes() {
  if (!saved.items) return [el('p', { class: 'info-panel__hint' }, 'Loading…')];
  if (!saved.items.length) return [el('p', { class: 'info-panel__hint' }, 'Nothing saved yet.')];
  return saved.items.map((t) => {
    const avatar = el('span', { class: `avatar avatar--sm accent-${t.row?.color ?? 'a5'}` });
    if (t.row) fillAvatar(avatar, t.row);
    else avatar.append(icon(t.type === 'savedMessagesTopicTypeMyNotes' ? 'bookmark' : 'person', 'icon--sm'));
    if (t.row) avatar.dataset.topicChat = String(t.row.id);
    return el('button', {
      class: 'info-panel__member info-panel__topic', type: 'button',
      onclick: () => emit('ui:saved-topic', { id: t.id, title: t.name }),
    },
    avatar,
    el('span', { class: 'info-panel__member-text' },
      el('span', { class: 'info-panel__member-name' }, t.name),
      el('span', { class: 'info-panel__label' }, topicPreview(t.last))),
    el('span', { class: 'info-panel__topic-date' }, t.last?.date ? listTime(t.last.date) : ''));
  });
}

const topicsTitle = () => (saved.count ? `${saved.count} ${saved.count === 1 ? 'chat' : 'chats'}` : 'Saved from');

/** Avatars that were not on disk: ordered with chats.avatars — wait and put them in. */
async function chaseTopicAvatars() {
  for (let i = 0; i < TOPIC_AVATAR_RETRIES; i += 1) {
    const waiting = (saved.items ?? []).filter((t) => t.row && !t.row.avatar);
    if (!waiting.length) return;
    await new Promise((r) => setTimeout(r, TOPIC_AVATAR_RETRY_MS));
    let rows;
    try {
      rows = (await hooks.call('chats.rows', { ids: waiting.map((t) => t.row.id) }))?.items ?? [];
    } catch {
      return;
    }
    for (const row of rows) {
      if (!row.avatar) continue;
      const item = waiting.find((t) => t.row.id === row.id);
      if (item) item.row = row;
      for (const box of body?.querySelectorAll(`[data-topic-chat="${row.id}"]`) ?? []) fillAvatar(box, row);
    }
  }
}

async function loadSavedTopics(box, title) {
  if (Date.now() - saved.at < SAVED_REFRESH_MS) return;
  saved.at = Date.now();
  try {
    await hooks.call('admin', { steps: [{ key: 'r', method: 'loadSavedMessagesTopics', params: { limit: 100 }, soft: true }] });
    await new Promise((r) => setTimeout(r, 200));
    const raw = await hooks.call('td.kept', { types: ['updateSavedMessagesTopic:', 'updateSavedMessagesTopicCount'] }) ?? {};
    const parse = (t) => { try { return JSON.parse(t); } catch { return null; } };
    const topics = Object.keys(raw).filter((k) => k.startsWith('updateSavedMessagesTopic:'))
      .map((k) => parse(raw[k])?.topic).filter((t) => t && t.order && t.order !== '0')
      .sort((a, b) => (BigInt(b.order) > BigInt(a.order) ? 1 : -1));
    const ids = topics.map((t) => t.type?.chat_id).filter(Boolean);
    const rows = ids.length ? (await hooks.call('chats.rows', { ids }))?.items ?? [] : [];
    const byId = new Map(rows.map((r) => [r.id, r]));
    const missing = rows.filter((r) => !r.avatar).map((r) => r.id);
    if (missing.length) hooks.call('chats.avatars', { ids: missing }).catch(() => {});
    saved = {
      at: saved.at,
      count: parse(raw.updateSavedMessagesTopicCount)?.topic_count ?? topics.length,
      items: topics.map((t) => {
        const type = t.type?.['@type'];
        const row = byId.get(t.type?.chat_id) ?? null;
        const name = type === 'savedMessagesTopicTypeMyNotes' ? 'My notes'
          : type === 'savedMessagesTopicTypeAuthorHidden' ? 'Author hidden' : (row?.title ?? 'Unknown chat');
        return { id: t.id, name, type, row, last: t.last_message };
      }),
    };
    if (box.isConnected) {
      clear(box).append(...topicNodes());
      title.textContent = topicsTitle();
    }
    chaseTopicAvatars();
  } catch (error) {
    saved.at = 0;
    hooks.report(error);
  }
}

// ------------------------------------------------------------ gifts
// Profile gifts (gifts.list — getReceivedGifts): a grid of stickers with
// price and sender, a kind filter (as in the native client: all, limited,
// unlimited, unique) and sorting by price. Opened by the "N gifts" row in
// the panel and the Gifts button in the chat header.
const GIFT_KINDS = [['all', 'All'], ['limited', 'Limited'], ['unlimited', 'Unlimited'], ['unique', 'Unique']];

let view = 'info';         // 'info' | 'gifts' | 'media' | 'similar'
// Similar channels (chat.similar): the channel they are for, the rows and the view's node.
let similar = { chatId: null, items: null, node: null };
const similarMissing = new Set();
let similarBoxes = new Map();
let gifts = { kind: 'all', sortByPrice: false, items: [], next: '', total: 0, loading: false };

/** A view change; tells the chat header which media grid is open (button highlight). */
// A transition between panel views (info, media, gifts, similar) — as
// between windows: first the new view's data (prepare; the old view stays
// in place meanwhile, the panel is "busy"), then the old one fades
// (VIEW_FADE_OUT_MS) and the new one appears, already with data (apply).
// Otherwise the view changed before content appeared in it, and the
// transition jerked. A closed panel — at once, loading — in the opened one.
const VIEW_FADE_OUT_MS = 150;
let viewSwitch = 0;

async function viewTransition(apply, prepare = null) {
  if (!open || !body?.childNodes.length) {
    apply(null);
    return;
  }
  const my = ++viewSwitch;
  let data = null;
  if (prepare) {
    panel.classList.add('is-busy');
    try {
      data = await prepare();
    } catch {
      data = null;
    }
    if (my !== viewSwitch) return;
    panel.classList.remove('is-busy');
  }
  body.classList.add('is-leaving');
  await new Promise((r) => setTimeout(r, VIEW_FADE_OUT_MS));
  if (my !== viewSwitch) return;
  apply(data);
  body.classList.remove('is-leaving');
}

/** Back to the info — with a transition. */
const backToInfo = () => viewTransition(() => { setView('info'); render(); });

function setView(next) {
  const was = view === 'media' ? media.filter : '';
  if (view === 'media' && next !== 'media') {
    mediaSeq += 1;      // the running load's answer has nowhere to go any more
    mediaParts = null;
    if (mediaFloat) mediaFloat.hidden = true;
  }
  view = next;
  const now = view === 'media' ? media.filter : '';
  if (was !== now) emit('info:media-view', now);
}

// ------------------------------------------------------- similar
// Similar channels, as in the native client: a list in the panel; a click
// opens the channel (openChatSimilarChat — Telegram counts the choice).
function openSimilar() {
  const chatId = info?.chatId ?? null;
  viewTransition((pre) => openSimilarNow(chatId, pre),
    () => hooks.call('chat.similar', { chatId }));
}

/** pre — the already loaded chat.similar answer (or null — load it). */
function openSimilarNow(chatId, pre) {
  setView('similar');
  similar = { chatId, items: null, node: null };
  if (!open) setOpen(true);
  if (pre) {
    applySimilar(pre);
    return;
  }
  renderSimilar();
  loadSimilar();
}

async function loadSimilar() {
  const chatId = similar.chatId;
  let answer;
  try {
    answer = await hooks.call('chat.similar', { chatId });
  } catch (error) {
    hooks.report(error);
    answer = { items: [] };
  }
  if (view !== 'similar' || similar.chatId !== chatId) return;
  applySimilar(answer);
}

function applySimilar(answer) {
  similar.items = answer.items ?? [];
  similar.node = null;
  renderSimilar();
  const missing = similar.items.filter((c) => !c.avatar).map((c) => c.id);
  missing.forEach((id) => similarMissing.add(id));
  if (missing.length) hooks.call('chats.avatars', { ids: missing }).catch(() => {});
}

function similarRow(chat) {
  const avatar = el('span', { class: `avatar media-row__avatar accent-${chat.color || 'a5'}` });
  fillAvatar(avatar, chat);
  if (!similarBoxes.has(chat.id)) similarBoxes.set(chat.id, new Set());
  similarBoxes.get(chat.id).add(avatar);
  return el('button', {
    class: 'media-row', type: 'button',
    onclick: () => {
      hooks.call('chat.similarOpened', { chatId: similar.chatId, openedId: chat.id }).catch(() => {});
      setActiveChat(chat.id);
    },
  },
  el('span', { class: 'media-row__cover is-round' }, avatar),
  el('span', { class: 'media-row__text' },
    el('span', { class: 'media-row__title' }, chat.title || 'Channel'),
    chat.preview ? el('span', { class: 'media-row__desc' }, chat.preview) : null));
}

function renderSimilar() {
  // Drawn already — do not rebuild (srv:chats re-reads the panel).
  if (similar.node?.isConnected) return;
  const back = el('button', {
    class: 'btn info-panel__back', type: 'button',
    onclick: backToInfo,
  }, icon('chevron-left'), info?.title || 'Back');
  const items = similar.items;
  const title = el('div', { class: 'info-panel__section-title' },
    items ? `${items.length} similar channels` : 'Similar channels');
  similarBoxes = new Map();
  const list = items === null
    ? el('p', { class: 'info-panel__hint' }, 'Loading…')
    : items.length
      ? el('div', { class: 'media-list' }, ...items.map(similarRow))
      : el('p', { class: 'info-panel__hint' }, 'No similar channels.');
  similar.node = el('div', {}, back, title, list);
  clear(body).append(similar.node);
  body.scrollTop = 0;
}

/** Avatars of similar channels that finished downloading — into place. */
async function refreshSimilarAvatars() {
  if (view !== 'similar' || !similarMissing.size) return;
  let answer;
  try {
    answer = await hooks.call('chats.rows', { ids: [...similarMissing] });
  } catch {
    return;
  }
  for (const row of answer?.items ?? []) {
    if (!row.avatar) continue;
    similarMissing.delete(row.id);
    for (const box of similarBoxes.get(row.id) ?? []) fillAvatar(box, row);
  }
}

function openGifts() {
  const chatId = info?.chatId;
  viewTransition(openGiftsNow, () => hooks.call('gifts.list', {
    chatId, kind: gifts.kind, sortByPrice: gifts.sortByPrice, offset: '',
  }));
}

/** pre — the already loaded gifts.list answer (or null — load it). */
function openGiftsNow(pre) {
  setView('gifts');
  gifts = { kind: gifts.kind, sortByPrice: gifts.sortByPrice, items: [], next: '', total: 0, loading: false };
  if (!open) setOpen(true);
  if (pre) {
    gifts.items = pre.gifts ?? [];
    gifts.next = pre.nextOffset ?? '';
    gifts.total = pre.total ?? gifts.items.length;
    renderGifts();
    return;
  }
  loadGifts(true);
}

// The gifts' own request counter. The answer used to be checked against
// the counter of INFO requests (asked): going to another chat re-read the
// info, the answer with gifts was thrown away as stale, and leaving past
// the redraw left "Loading gifts…" forever (a live case: a gift → the
// sender → their gifts).
let giftsSeq = 0;

async function loadGifts(fresh) {
  if (!info) return;
  // "More" waits for a running load; a new one (filter, another chat) overrides it.
  if (!fresh && gifts.loading) return;
  const my = ++giftsSeq;
  const chatId = info.chatId;
  gifts.loading = true;
  renderGifts();
  try {
    const r = await hooks.call('gifts.list', {
      chatId, kind: gifts.kind, sortByPrice: gifts.sortByPrice,
      offset: fresh ? '' : gifts.next,
    });
    if (my !== giftsSeq) return;   // overridden by a new load — it will draw
    gifts.items = fresh ? (r.gifts ?? []) : gifts.items.concat(r.gifts ?? []);
    gifts.next = r.nextOffset ?? '';
    gifts.total = r.total ?? gifts.items.length;
  } catch (error) {
    if (my !== giftsSeq) return;
    hooks.report(error);
  }
  gifts.loading = false;
  if (view === 'gifts' && info?.chatId === chatId) renderGifts();
}

function giftSticker(g, cls) {
  const s = g.sticker;
  if (s?.url && s.url !== '-') return el('span', { class: cls }, stickerNode({ url: s.url, format: s.format }));
  return el('span', { class: `${cls} is-empty` }, icon('gift'));
}

function senderBadge(g) {
  const avatar = el('span', { class: `avatar gift-tile__sender accent-${g.senderColor || 'a5'}` });
  fillAvatar(avatar, { title: g.sender || '?', avatar: g.senderAvatar, avatarThumb: g.senderThumb });
  return avatar;
}

function giftLabel(g) {
  if (g.unique) return g.number ? `#${g.number}` : 'Unique';
  return g.stars ? `\u2B50 ${g.stars}` : 'Gift';
}

/** Gift details — a window on top, as in the native client. */
function giftDetails(g) {
  const dialog = el('dialog', { class: 'confirm gift-details' });
  const rows = [];
  const row = (label, value) => {
    if (value) rows.push(el('div', { class: 'gift-details__row' },
      el('span', { class: 'gift-details__label' }, label),
      typeof value === 'string' ? el('span', {}, value) : value));
  };
  // The sender — as a link: the private chat with the person or the channel itself.
  const canOpen = g.sender && (g.senderUserId || g.senderChatId);
  row('From', canOpen
    ? el('button', {
      class: 'gift-details__link', type: 'button',
      onclick: () => {
        dialog.close();
        if (g.senderUserId) emit('ui:open-contact', { userId: g.senderUserId });
        else setActiveChat(Number(g.senderChatId));
      },
    }, g.sender)
    : g.sender || (g.isPrivate ? 'Hidden sender' : 'Unknown'));
  row('Date', new Date(g.date * 1000).toLocaleString());
  if (g.unique) {
    row('Model', g.model);
    row('Symbol', g.symbol);
    row('Backdrop', g.backdrop);
  } else {
    row('Value', g.stars ? `${g.stars} Telegram Stars` : '');
    row('Availability', g.limited ? 'Limited' : 'Unlimited');
  }
  if (g.sellStars) row('Can be converted', `${g.sellStars} Telegram Stars`);
  row('Shown in profile', g.isSaved ? 'Yes' : 'No');
  // The native append, unlike el(), does not skip null — it would become
  // the text "null". So only what is there.
  dialog.append(...[
    giftSticker(g, 'gift-details__sticker'),
    el('div', { class: 'gift-details__title' },
      g.unique ? `${g.title || 'Unique gift'}${g.number ? ` #${g.number}` : ''}` : 'Gift'),
    g.text ? el('p', { class: 'gift-details__text' }, g.text) : null,
    ...rows,
    el('div', { class: 'confirm__buttons' },
      el('button', { class: 'btn confirm__button', type: 'button', onclick: () => dialog.close() }, 'Close')),
  ].filter(Boolean));
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) dialog.close();
  });
  dialog.addEventListener('close', () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
}

function renderGifts() {
  const back = el('button', {
    class: 'btn info-panel__back', type: 'button',
    onclick: backToInfo,
  }, icon('chevron-left'), info?.title || 'Back');
  const chips = el('div', { class: 'gift-filter' },
    ...GIFT_KINDS.map(([kind, label]) => el('button', {
      class: `gift-filter__chip${gifts.kind === kind ? ' is-active' : ''}`, type: 'button',
      onclick: () => {
        if (gifts.kind === kind) return;
        gifts.kind = kind;
        gifts.items = [];
        loadGifts(true);
      },
    }, label)),
    el('button', {
      class: `gift-filter__chip${gifts.sortByPrice ? ' is-active' : ''}`, type: 'button',
      title: 'Sort by value instead of date',
      onclick: () => {
        gifts.sortByPrice = !gifts.sortByPrice;
        gifts.items = [];
        loadGifts(true);
      },
    }, 'By value'));
  const grid = el('div', { class: 'gift-grid' },
    ...gifts.items.map((g) => el('button', {
      class: `gift-tile${g.unique ? ' is-unique' : ''}`, type: 'button',
      title: g.sender ? `From ${g.sender}` : '',
      onclick: () => giftDetails(g),
    },
    // Who gave it — a circle in the corner, as in the native client.
    g.sender || g.senderAvatar ? senderBadge(g) : null,
    giftSticker(g, 'gift-tile__sticker'),
    el('span', { class: 'gift-tile__label' }, giftLabel(g)),
    g.sender ? el('span', { class: 'gift-tile__from' }, g.sender) : null)));
  const parts = [back,
    el('div', { class: 'info-panel__section-title' },
      gifts.total ? `${gifts.total} gifts` : 'Gifts'),
    chips];
  if (gifts.items.length) parts.push(grid);
  if (gifts.loading) {
    parts.push(el('p', { class: 'info-panel__hint' }, 'Loading gifts…'));
  } else if (!gifts.items.length) {
    parts.push(el('p', { class: 'info-panel__hint' }, 'No gifts here.'));
  } else if (gifts.next) {
    parts.push(el('button', {
      class: 'btn info-panel__more', type: 'button', onclick: () => loadGifts(false),
    }, 'Show more'));
  }
  clear(body).append(...parts);
}

// ------------------------------------------------------------ media
// The chat's media in the panel, as in the native client (media.list —
// searchChatMessages with a filter): photos, videos and GIFs — a grid of
// square previews, music, links, voice messages, files and pinned ones — a
// list of rows. A click on a tile or row does not close the panel: the
// history scrolls to that message (ui:open-source), and one can go on. The
// next page loads when the panel's scroll nears the end; new items are
// appended, what is shown already is not rebuilt.
//
// A kind: the key, the button label, the counter label, the empty list, the layout.
const MEDIA_KINDS = [
  ['photo', 'Photos', 'photos', 'No photos here.', 'grid'],
  ['video', 'Videos', 'videos', 'No videos here.', 'grid'],
  ['gif', 'GIFs', 'GIFs', 'No GIFs here.', 'grid'],
  ['audio', 'Music', 'audio files', 'No music here.', 'list'],
  ['link', 'Links', 'links', 'No links here.', 'list'],
  ['voice', 'Voice', 'voice messages', 'No voice messages here.', 'list'],
  ['file', 'Files', 'files', 'No files here.', 'list'],
  ['poll', 'Polls', 'polls', 'No polls here.', 'list'],
  ['pinned', 'Pinned', 'pinned messages', 'No pinned messages.', 'list'],
];
// How many pixels before the end of the scroll to ask for the next page.
const MEDIA_PRELOAD_PX = 400;
// Colours of the placeholder letter of a link without a picture — the
// fallback palette (f0..f7, as for senders without their own colour).
const MEDIA_LETTER_COLORS = 8;

let media = { filter: 'photo', chatId: null, items: [], next: 0, total: 0, loading: false, done: false };
let mediaParts = null;     // { title, grid, foot } — the nodes of the open view
// Days, as in the history: a divider for every new day and a floating
// label over the scroll (util/floatdate.js). mediaDay — the day of the last
// appended item, so the next page continues the split.
let mediaDay = '';
let mediaFloat = null;
// The label's offset from the top of the panel — top of .info-panel__float-date.
const MEDIA_FLOAT_TOP = 16;
let mediaSeq = 0;          // its own request counter, as for gifts
let mediaCurrent = null;   // the tile or row whose message the history went to

function mediaKind() {
  return MEDIA_KINDS.find(([k]) => k === media.filter) ?? MEDIA_KINDS[0];
}

function openMedia(filter) {
  const chatId = viewChatId();
  viewTransition((pre) => openMediaNow(filter, pre),
    () => hooks.call('media.list', { chatId, filter, from: 0 }));
}

/** pre — the already loaded first page of media.list (or null). */
function openMediaNow(filter, pre) {
  // A running load of the previous view will no longer append here (loadMedia).
  mediaSeq += 1;
  media = { filter, chatId: viewChatId(), items: [], next: 0, total: 0, loading: false, done: false };
  if (pre) {
    media.items = pre.items ?? [];
    media.next = pre.nextFrom ?? 0;
    media.total = pre.total ?? media.items.length;
    media.done = !media.next || !media.items.length;
  }
  mediaCurrent = null;
  setView('media');
  // A view change inside media (Photos -> Music) does not change view — we
  // tell the header ourselves.
  emit('info:media-view', filter);
  if (!open) setOpen(true);
  renderMedia();
  if (pre) mediaMaybeMore();
  else loadMedia(true);
}

async function loadMedia(fresh) {
  if (!fresh && (media.loading || media.done)) return;
  const my = ++mediaSeq;
  const { chatId, filter } = media;
  media.loading = true;
  mediaFoot();
  try {
    const r = await hooks.call('media.list', { chatId, filter, from: fresh ? 0 : media.next });
    if (my !== mediaSeq) return;   // overridden — another view or another chat
    const items = r.items ?? [];
    media.items = media.items.concat(items);
    media.next = r.nextFrom ?? 0;
    media.total = r.total ?? media.items.length;
    media.done = !media.next || !items.length;
    if (view === 'media' && mediaParts) {
      mediaParts.grid.append(...withDays(items));
      mediaParts.title.textContent = mediaTitle();
      mediaFloatUpdate();
    }
  } catch (error) {
    if (my !== mediaSeq) return;
    media.done = true;
    hooks.report(error);
  }
  media.loading = false;
  if (view !== 'media') return;
  mediaFoot();
  // The page did not fill the panel — there will be no scroll, ask for the next one.
  mediaMaybeMore();
}

function mediaTitle() {
  const [, label, plural] = mediaKind();
  return media.total ? `${media.total} ${plural}` : label;
}

/** Go to the message in the history; the tile or row is marked. */
function mediaGo(node, item) {
  mediaCurrent?.classList.remove('is-current');
  mediaCurrent = node;
  node.classList.add('is-current');
  emit('ui:open-source', { chatId: media.chatId, messageId: item.id });
}

function realUrl(item) {
  return item.url && item.url !== '-' ? item.url : '';
}

/** A preview: a picture or a silent clip (the MPEG4 preview of GIFs and videos). */
function mediaPreview(item, cls) {
  const url = realUrl(item);
  if (!url) return null;
  if (item.thumbKind !== 'video') return el('img', { class: cls, src: url, alt: '', loading: 'lazy' });
  const video = el('video', { class: cls, src: url, loop: true, playsinline: true, preload: 'metadata' });
  video.muted = true;
  return video;
}

/**
 * Items with day dividers — the same markup as the history's
 * (.history__date with data-day), so both the look and the floating label
 * are the same. In the grid a divider takes the whole row (.media-day).
 */
function withDays(items) {
  const out = [];
  for (const item of items) {
    const day = item.date ? dateLabel(item.date) : '';
    if (day && day !== mediaDay) {
      mediaDay = day;
      out.push(el('div', { class: 'history__date media-day', dataset: { day } }, el('span', {}, day)));
    }
    out.push(mediaItem(item));
  }
  return out;
}

function mediaFloatUpdate() {
  if (!mediaFloat) return;
  if (view !== 'media' || !mediaParts) {
    mediaFloat.hidden = true;
    return;
  }
  updateFloatDate(body, mediaParts.grid, mediaFloat, MEDIA_FLOAT_TOP);
}

function mediaItem(item) {
  if (item.kind === 'audio') return audioRow(item);
  if (item.kind === 'voice') return voiceRow(item);
  if (item.kind === 'file') return fileRow(item);
  // A poll — as a line, like a pinned one: "Poll: question" and the author.
  if (item.kind === 'pinned' || item.kind === 'poll') return pinnedRow(item);
  if (item.kind === 'link') return linkRow(item);
  return mediaTile(item);
}

function mediaTile(item) {
  const preview = mediaPreview(item, 'media-tile__img');
  const tile = el('button', {
    class: 'media-tile', type: 'button',
    title: { video: 'Video', gif: 'GIF' }[item.kind] ?? 'Photo',
    onclick: () => mediaGo(tile, item),
  },
  // The backdrop — the blurred minithumbnail while there is no preview (or it did not download).
  item.thumb ? el('img', { class: 'media-tile__blur', src: item.thumb, alt: '' }) : null,
  preview,
  item.kind === 'video'
    ? el('span', { class: 'media-tile__badge' }, icon('play', 'icon--sm'),
      item.duration ? duration(item.duration) : null)
    : null,
  item.kind === 'gif' ? el('span', { class: 'media-tile__badge' }, 'GIF') : null);
  // The preview clip comes alive under the mouse, as in the native client:
  // two dozen playing at once in one panel are of no use.
  if (preview?.tagName === 'VIDEO') {
    tile.addEventListener('mouseenter', () => preview.play().catch(() => {}));
    tile.addEventListener('mouseleave', () => preview.pause());
  }
  return tile;
}

function audioRow(item) {
  const url = realUrl(item);
  let cover = icon('audio');
  if (url) cover = el('img', { class: 'media-row__img', src: url, alt: '', loading: 'lazy' });
  else if (item.thumb) cover = el('img', { class: 'media-row__img is-blur', src: item.thumb, alt: '' });
  const sub = [item.performer, item.duration ? duration(item.duration) : ''].filter(Boolean).join(' · ');
  const row = el('button', {
    class: 'media-row', type: 'button', onclick: () => mediaGo(row, item),
  },
  el('span', { class: 'media-row__cover' }, cover),
  el('span', { class: 'media-row__text' },
    el('span', { class: 'media-row__title' }, item.title || item.fileName || 'Audio'),
    sub ? el('span', { class: 'media-row__sub' }, sub) : null),
  el('span', { class: 'media-row__date' }, listTime(item.date)));
  return row;
}

/** A placeholder square with letters; the colour comes from the text, stable (f0..f7). */
function letterTile(text, label) {
  let hash = 0;
  for (const ch of text) hash = (hash * 31 + ch.codePointAt(0)) >>> 0;
  const long = typeof label === 'string' && label.length > 1;
  return el('span', { class: `media-row__letter accent-f${hash % MEDIA_LETTER_COLORS}${long ? ' is-ext' : ''}` }, label);
}

/** A voice message: the sender's avatar, their name, the duration; the date on the right. */
function voiceRow(item) {
  const avatar = el('span', { class: `avatar media-row__avatar accent-${item.senderColor || 'a5'}` });
  fillAvatar(avatar, { title: item.sender || '?', avatar: item.senderAvatar, avatarThumb: item.senderThumb });
  const row = el('button', {
    class: `media-row${item.isListened ? '' : ' is-unlistened'}`, type: 'button',
    onclick: () => mediaGo(row, item),
  },
  el('span', { class: 'media-row__cover is-round' }, avatar),
  el('span', { class: 'media-row__text' },
    el('span', { class: 'media-row__title' }, item.sender || 'Voice message'),
    el('span', { class: 'media-row__sub media-row__sub--icon' }, icon('mic', 'icon--sm'),
      item.duration ? duration(item.duration) : 'Voice message')),
  el('span', { class: 'media-row__date' }, listTime(item.date)));
  return row;
}

/** A pinned one: the message's picture or the sender's avatar, the name, the text. */
function pinnedRow(item) {
  const url = realUrl(item);
  let cover;
  let round = false;
  if (url) cover = el('img', { class: 'media-row__img', src: url, alt: '', loading: 'lazy' });
  else if (item.thumb) cover = el('img', { class: 'media-row__img is-blur', src: item.thumb, alt: '' });
  else {
    round = true;
    cover = el('span', { class: `avatar media-row__avatar accent-${item.senderColor || 'a5'}` });
    fillAvatar(cover, { title: item.sender || '?', avatar: item.senderAvatar, avatarThumb: item.senderThumb });
  }
  const row = el('button', {
    class: 'media-row', type: 'button', onclick: () => mediaGo(row, item),
  },
  el('span', { class: `media-row__cover${round ? ' is-round' : ''}` }, cover),
  el('span', { class: 'media-row__text' },
    el('span', { class: 'media-row__title' }, item.sender || 'Pinned message'),
    item.text ? el('span', { class: 'media-row__desc' }, item.text) : null),
  el('span', { class: 'media-row__date' }, listTime(item.date)));
  return row;
}

/** A file: a preview or the extension on a coloured square, name, size; the date on the right. */
function fileRow(item) {
  const url = realUrl(item);
  const name = item.fileName || 'File';
  const dot = name.lastIndexOf('.');
  const ext = dot > 0 && name.length - dot <= 6 ? name.slice(dot + 1).toUpperCase() : '';
  let cover;
  if (url) cover = el('img', { class: 'media-row__img', src: url, alt: '', loading: 'lazy' });
  else if (item.thumb) cover = el('img', { class: 'media-row__img is-blur', src: item.thumb, alt: '' });
  else cover = letterTile(ext || name, ext || icon('file'));
  const row = el('button', {
    class: 'media-row', type: 'button', title: name, onclick: () => mediaGo(row, item),
  },
  el('span', { class: 'media-row__cover' }, cover),
  el('span', { class: 'media-row__text' },
    el('span', { class: 'media-row__title' }, name),
    item.size ? el('span', { class: 'media-row__sub' }, fileSize(item.size)) : null),
  el('span', { class: 'media-row__date' }, listTime(item.date)));
  return row;
}

function hostOf(url) {
  try {
    return new URL(/^[a-z][a-z0-9+.-]*:/i.test(url) ? url : `https://${url}`).hostname.replace(/^www\./, '');
  } catch {
    return url;
  }
}

/** The message's addresses without repeats: text entities, otherwise the preview's address. */
function linkUrls(item) {
  const text = item.text ?? '';
  const urls = (item.urls ?? []).map((u) => u.url || text.substr(u.offset, u.length)).filter(Boolean);
  if (!urls.length && item.preview?.url) urls.push(item.preview.url);
  return [...new Set(urls)];
}

function linkRow(item) {
  const urls = linkUrls(item);
  const p = item.preview;
  const host = hostOf(urls[0] ?? p?.url ?? '');
  const url = realUrl(item);
  let pic;
  if (url) {
    pic = el('img', { class: 'media-row__img', src: url, alt: '', loading: 'lazy' });
  } else if (item.thumb) {
    pic = el('img', { class: 'media-row__img is-blur', src: item.thumb, alt: '' });
  } else {
    // The site's letter on a coloured square; the colour comes from the site name, stable.
    const name = p?.siteName || host;
    pic = letterTile(name, initial(name));
  }
  // The row has links — it cannot be a button (a link inside a button is
  // not allowed), so a div with the button role and Enter from the keyboard.
  const row = el('div', {
    class: 'media-row media-row--link', role: 'button', tabindex: '0',
    onclick: () => mediaGo(row, item),
    onkeydown: (event) => {
      if (event.key === 'Enter' && event.target === row) mediaGo(row, item);
    },
  },
  el('span', { class: 'media-row__cover' }, pic),
  el('span', { class: 'media-row__text' },
    el('span', { class: 'media-row__title' }, p?.title || p?.siteName || host || 'Link'),
    p?.description || item.text
      ? el('span', { class: 'media-row__desc' }, p?.description || item.text)
      : null,
    ...urls.map((u) => el('a', {
      class: 'media-row__url', href: /^[a-z][a-z0-9+.-]*:/i.test(u) ? u : `https://${u}`,
      target: '_blank', rel: 'noopener',
      // The link opens itself (t.me — inside the app, ui/links.js); going to
      // the message is not needed then.
      onclick: (event) => event.stopPropagation(),
    }, u.replace(/^https?:\/\//i, '')))),
  el('span', { class: 'media-row__date' }, listTime(item.date)));
  return row;
}

function mediaFoot() {
  if (!mediaParts) return;
  const { foot } = mediaParts;
  if (media.loading) foot.textContent = 'Loading…';
  else if (!media.items.length) foot.textContent = mediaKind()[3];
  else foot.textContent = '';
  foot.hidden = !foot.textContent;
}

function mediaMaybeMore() {
  if (view !== 'media' || media.loading || media.done) return;
  if (body.scrollHeight - body.scrollTop - body.clientHeight < MEDIA_PRELOAD_PX) loadMedia(false);
}

function renderMedia() {
  const back = el('button', {
    class: 'btn info-panel__back', type: 'button',
    onclick: backToInfo,
  }, icon('chevron-left'), info?.chatId === media.chatId && info.title ? info.title : 'Back');
  const chips = el('div', { class: 'gift-filter' },
    ...MEDIA_KINDS.map(([kind, label]) => el('button', {
      class: `gift-filter__chip${media.filter === kind ? ' is-active' : ''}`, type: 'button',
      onclick: () => { if (media.filter !== kind) openMedia(kind); },
    }, label)));
  const title = el('div', { class: 'info-panel__section-title' }, mediaTitle());
  mediaDay = '';
  const grid = el('div', { class: mediaKind()[4] === 'grid' ? 'media-grid' : 'media-list' },
    ...withDays(media.items));
  const foot = el('p', { class: 'info-panel__hint', hidden: true });
  mediaParts = { title, grid, foot };
  clear(body).append(back, title, chips, grid, foot);
  body.scrollTop = 0;
  mediaFoot();
  mediaFloatUpdate();
}

// ----------------------------------------------------------- render
function render() {
  const i = info;
  if (!i) return;
  if (view === 'gifts') {
    renderGifts();
    return;
  }
  if (view === 'media') {
    if (!mediaParts) renderMedia();
    return;
  }
  if (view === 'similar') {
    renderSimilar();
    return;
  }
  mediaParts = null;
  const avatar = el('span', { class: `avatar info-panel__avatar accent-${i.color}` });
  fillAvatar(avatar, {
    id: i.chatId, title: i.title, avatar: i.avatar, avatarThumb: i.avatarThumb, avatarAnim: i.avatarAnim,
  });

  const head = el('div', { class: 'info-panel__head' },
    el('button', {
      class: 'info-panel__avatar-btn', type: 'button',
      title: i.userId ? 'Photos' : '', onclick: (event) => openPhotos(i, event.currentTarget),
    }, avatar),
    el('div', { class: 'info-panel__title' }, i.title || ''),
    idLine(i),
    el('div', {
      class: `info-panel__status${i.status === 'userStatusOnline' ? ' is-online' : ''}`,
    }, statusLine(i)));

  const more = actionButton('dots', 'More', (event) => {
    const items = actions(i).map(([label, run]) => ({ label, onSelect: run }));
    if (items.length) openMenu(event.currentTarget, items);
  });
  const buttons = el('div', { class: 'info-panel__actions' },
    actionButton('chat', 'Chat', () => {
      // Info of someone else's contact — open the private chat with them.
      if (override !== null && override !== store.activeChatId) {
        const id = override;
        setOpen(false);
        setActiveChat(id);
        return;
      }
      // A channel — its discussion group: one cannot write into the channel itself.
      if (i.kind === 'channel' && i.linkedChatId) {
        setOpen(false);
        setActiveChat(i.linkedChatId);
        return;
      }
      setOpen(false);
      document.querySelector('.composer__input')?.focus();
    }),
    actionButton(i.muted ? 'bell-off' : 'bell', i.muted ? 'Unmute' : 'Mute', async () => {
      try {
        await hooks.call('chat.action', { id: i.chatId, action: i.muted ? 'unmute' : 'mute' });
      } catch (error) {
        hooks.report(error);
      }
      load();
    }),
    // A call: to a person — a private one (ui/call.js), voice or video;
    // to a group or channel — a video chat (ui/videochat.js).
    actionButton('mic', 'Call', (event) => {
      if (i.kind === 'group' || i.kind === 'channel') {
        emit('ui:vchat-open', { chatId: i.chatId, title: i.title });
        return;
      }
      if (i.kind !== 'user' || !i.userId) {
        hooks.notice('Calls are available with people, groups and channels');
        return;
      }
      openMenu(event.currentTarget, [
        { label: 'Voice call', onSelect: () => emit('ui:call-start', { userId: i.userId, video: false }) },
        { label: 'Video call', onSelect: () => emit('ui:call-start', { userId: i.userId, video: true }) },
      ]);
    }),
    more);

  const rows = [];
  if (i.phone) rows.push(infoRow(`+${i.phone}`, 'Phone', `+${i.phone}`));
  if (i.bio) rows.push(infoRow(i.bio, 'Bio', i.bio));
  if (i.description) rows.push(infoRow(i.description, i.kind === 'bot' ? 'About' : 'Description', i.description));
  if (i.username) rows.push(infoRow(`@${i.username}`, 'Username', `https://t.me/${i.username}`));
  if (i.birthdate) rows.push(infoRow(birthday(i.birthdate), 'Birthday', birthday(i.birthdate)));
  if (!i.username && i.inviteLink) rows.push(infoRow(i.inviteLink, 'Invite link', i.inviteLink));

  const counts = [];
  if (i.giftCount) {
    counts.push(el('button', {
      class: 'info-panel__count', type: 'button', onclick: () => openGifts(),
    }, icon('gift'), el('span', {}, `${i.giftCount} gifts`)));
  }
  for (const [key, iconName, label, filter] of COUNTS) {
    const n = i.counts?.[key] ?? 0;
    if (!n) continue;
    counts.push(el('button', {
      class: 'info-panel__count', type: 'button',
      onclick: () => (filter.startsWith('@') ? openMedia(filter.slice(1)) : emit('ui:set-filter', filter)),
    }, icon(iconName), el('span', {}, `${n} ${label}`)));
  }
  if (i.similarCount > 0) {
    counts.push(el('button', {
      class: 'info-panel__count', type: 'button', onclick: openSimilar,
    }, icon('channel'), el('span', {}, `${i.similarCount} similar channels`)));
  }

  const parts = [head, buttons];
  if (rows.length) parts.push(el('section', { class: 'info-panel__section' }, ...rows));
  if (counts.length) parts.push(el('section', { class: 'info-panel__section' }, ...counts));

  if (i.kind === 'self') {
    const box = el('div', { class: 'info-panel__members' }, ...topicNodes());
    const title = el('div', { class: 'info-panel__section-title' }, topicsTitle());
    parts.push(el('section', { class: 'info-panel__section' }, title, box));
    loadSavedTopics(box, title);
  }

  if ((i.kind === 'group') && i.canGetMembers) {
    // The chat's previous list — until the fresh one arrives: otherwise the
    // panel's height collapses during the request and the scroll is lost.
    const box = el('div', { class: 'info-panel__members' },
      ...(membersShown.chatId === i.chatId
        ? membersShown.nodes
        : [el('p', { class: 'info-panel__hint' }, 'Loading members…')]));
    parts.push(el('section', { class: 'info-panel__section' },
      el('div', { class: 'info-panel__section-title' },
        i.memberCount ? `${i.memberCount} members` : 'Members'),
      box));
    loadMembers(box, i);
  }

  const bottom = actions(i);
  if (bottom.length) {
    parts.push(el('section', { class: 'info-panel__section' },
      ...bottom.map(([label, run, danger]) => el('button', {
        class: `info-panel__link${danger ? ' is-danger' : ''}`, type: 'button', onclick: run,
      }, label))));
  }
  // The panel is rebuilt whole (including on srv:chats while it is open),
  // and the button the menu is open under (Call, More) is replaced with a
  // new one. A menu without an anchor does not close but falls into the
  // corner of the screen — so the anchor moves to the new button with the
  // same label (reanchorMenu does nothing if the menu was not opened from it).
  const oldActions = new Map([...body.querySelectorAll('.info-panel__action')]
    .map((n) => [n.textContent, n]));
  clear(body).append(...parts);
  for (const n of body.querySelectorAll('.info-panel__action')) {
    const old = oldActions.get(n.textContent);
    if (old) reanchorMenu(old, n);
  }
}

// ------------------------------------------------------------ mount
export function mountInfoPanel(box, options) {
  hooks = options ?? {};
  toggle = el('button', {
    class: 'info-toggle', type: 'button', title: 'Chat info', hidden: true,
    'aria-expanded': 'false',
    onclick: () => setOpen(!open),
  }, el('span', { class: 'info-toggle__glyph', 'aria-hidden': 'true' }, 'i'),
  el('span', { class: 'u-sr-only' }, 'Chat info'));
  body = el('div', { class: 'info-panel__body' });
  panel = el('aside', { class: 'info-panel', 'aria-label': 'Chat info' },
    el('button', {
      class: 'btn btn--icon info-panel__close', type: 'button', title: 'Close',
      onclick: () => setOpen(false),
    }, icon('close'), el('span', { class: 'u-sr-only' }, 'Close')),
    body);
  panel.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') setOpen(false);
  });
  body.addEventListener('scroll', () => {
    mediaMaybeMore();
    mediaFloatUpdate();
  }, { passive: true });
  // The floating media date — over the panel body, as in the history.
  mediaFloat = el('div', { class: 'history__float-date info-panel__float-date', hidden: true }, el('span'));
  panel.append(mediaFloat);
  box.append(toggle, panel);
  // "Contact info" from the message menu: the private chat with the sender
  // (createPrivateChat — bot.userChat) and its info.
  on('ui:contact-info', async ({ userId }) => {
    try {
      const r = await hooks.call('bot.userChat', { userId: String(userId) });
      if (r?.chatId) openInfoFor(r.chatId);
    } catch (error) {
      hooks.report(error);
    }
  });
  // The avatar in the chat header: for a person — the gallery of their
  // photos, for a group and channel (they have no avatar history) — the panel itself.
  on('ui:chat-photos', async ({ anchor } = {}) => {
    const chatId = store.activeChatId;
    if (chatId === null) return;
    let i = info && info.chatId === chatId ? info : null;
    if (!i) {
      try {
        i = await hooks.call('chat.info', { chatId });
      } catch (error) {
        hooks.report(error);
        return;
      }
    }
    if (i?.userId) openPhotos(i, anchor ?? null);
    else if (!open) setOpen(true);
  });
  // The Gifts button in the chat header (ui/chat-header.js).
  // The media buttons in the chat header (Photos … Files): a grid or a list,
  // a repeated click — close.
  on('ui:open-media', (filter) => {
    if (store.activeChatId === null) return;
    if (open && view === 'media' && media.filter === filter && media.chatId === store.activeChatId) {
      viewTransition(() => {
        setView('info');
        mediaParts = null;
        render();
      });
      return;
    }
    openMedia(filter);
  });
  on('ui:open-gifts', async () => {
    if (store.activeChatId === null) return;
    if (!open || !info || info.chatId !== store.activeChatId) {
      setView('info');
      setOpen(true);
      // Gifts are requested on behalf of the owner from chat.info — wait for it.
      const wait = () => new Promise((resolve) => setTimeout(resolve, 100));
      for (let n = 0; n < 50 && (!info || info.chatId !== store.activeChatId); n += 1) await wait();
    }
    if (info) openGifts();
  });

  on('store:active', () => {
    override = null;
    toggle.hidden = store.activeChatId === null;
    if (store.activeChatId === null) setOpen(false);
    else if (open) load();
  });
  // Joined, left, blocked, renamed — the chat list changes; the open panel
  // is re-read, but not more often than once every few seconds.
  let last = 0;
  on('srv:chats', () => {
    if (open && view === 'similar' && similarMissing.size) refreshSimilarAvatars();
    if (!open || loadingFor !== null || Date.now() - last < 5000) return;
    last = Date.now();
    load();
  });
}
