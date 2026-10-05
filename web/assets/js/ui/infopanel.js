import { el, clear } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { copyText } from '../util/clipboard.js';
import { openMenu } from '../util/menu.js';
import { openViewer } from './viewer.js';
import { formDialog, field, pickChats } from './bots.js';
import { statusText } from './chat-list.js';
import { stickerNode } from './message.js';

// Панель информации о чате — человек, бот, группа или канал. Открывается
// кнопкой «i» в правом верхнем углу истории и выезжает справа поверх неё
// (не как у официального клиента — по просьбе пользователя).
//
// Что внутри, повторяет нативный клиент: аватарка (у людей — галерея их
// фото), имя и статус, кнопки Chat / Mute / Call / More, телефон, «о себе»,
// имя пользователя, день рождения, описание и ссылка группы, счётчики
// медиа (клик — тот же фильтр истории, что в шапке чата), подарки,
// участники группы и действия: поделиться контактом, добавить / изменить /
// удалить контакт, заблокировать, выйти из группы.
//
// Данные — мост: chat.info, chat.members, info.action (webapi.pas).

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'];

// Счётчики медиа: ключ из chat.info, подпись и фильтр истории (тот же, что
// у кнопок в шапке чата — FILTERS в ui/chat-header.js).
const COUNTS = [
  ['photo', 'image', 'photos', 'searchMessagesFilterPhoto'],
  ['video', 'video', 'videos', 'searchMessagesFilterVideo'],
  ['document', 'file', 'files', 'searchMessagesFilterDocument'],
  ['audio', 'audio', 'audio files', 'searchMessagesFilterAudio'],
  ['url', 'link', 'links', 'searchMessagesFilterUrl'],
  ['voice', 'mic', 'voice messages', 'searchMessagesFilterVoiceNote'],
  ['animation', 'gif', 'GIFs', 'searchMessagesFilterAnimation'],
];

let hooks = {};
let toggle = null;
let panel = null;
let body = null;
let open = false;
let info = null;       // последний ответ chat.info
let loadingFor = null; // чат, для которого идёт запрос
let asked = 0;         // номер запроса: устаревший ответ отбрасывается

function setOpen(on) {
  open = on;
  panel.classList.toggle('is-open', on);
  toggle.classList.toggle('is-active', on);
  toggle.setAttribute('aria-expanded', String(on));
  if (on) load();
}

async function load() {
  const chatId = store.activeChatId;
  if (!open || chatId === null) return;
  const my = ++asked;
  loadingFor = chatId;
  if (!info || info.chatId !== chatId) {
    clear(body).append(el('p', { class: 'info-panel__hint' }, 'Loading…'));
  }
  try {
    const next = await hooks.call('chat.info', { chatId });
    if (my !== asked) return;
    // Другой чат — подарки прежнего ни к чему.
    if (info && info.chatId !== chatId) view = 'info';
    // Мост называет личку 'private' (и 'secret' — секретный чат), как
    // список чатов (ChatKindStr); панели это один вид — человек. Без этого
    // у контактов не было ни действий, ни меню More.
    if (next.kind === 'private' || next.kind === 'secret') next.kind = 'user';
    info = next;
    // На подарках фоновое обновление сведений сетку не перестраивает:
    // она от них не зависит, а перестройка заново запускала стикеры и
    // не давала разглядеть элементы в инспекторе.
    if (view === 'gifts') return;
    render();
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

/** Строка сведений: значение крупно, подпись мелко; клик — копировать. */
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

/** «Add contact» с карточки контакта в истории (ui:add-contact, main.js). */
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

/** Действия по виду чата — и внизу панели, и в меню «More». */
function actions(i) {
  const list = [];
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
  if (i.kind === 'group' || i.kind === 'channel') {
    const what = i.kind === 'channel' ? 'Leave channel' : 'Leave group';
    list.push([what, () => confirmAct(`${what}?`, 'Leave',
      { action: 'chat.leave', chatId: String(i.chatId) }, 'Left'), true]);
  }
  return list;
}

async function openPhotos(i) {
  if (!i.userId) return;
  try {
    const r = await hooks.call('account.photos', { userId: i.userId });
    const photos = (r.photos ?? []).filter((p) => p.url && p.url !== '-');
    if (!photos.length) return;
    openViewer(photos.map((p) => (p.animUrl && p.animUrl !== '-'
      ? { id: p.id, kind: 'animation',
        media: { url: p.animUrl, thumbUrl: p.url, thumb: p.url, w: p.animSize || p.w, h: p.animSize || p.h } }
      : { id: p.id, kind: 'photo',
        media: { fullUrl: p.url, url: p.url, thumb: p.thumb, w: p.w, h: p.h, fullW: p.w, fullH: p.h } })), 0);
  } catch (error) {
    hooks.report(error);
  }
}

async function loadMembers(box, i) {
  try {
    const r = await hooks.call('chat.members', { chatId: i.chatId });
    if (!info || info.chatId !== i.chatId) return;
    const members = (r.members ?? []).sort((a, b) => {
      const rank = (m) => (m.role === 'owner' ? 0 : m.role === 'admin' ? 1 : 2);
      return rank(a) - rank(b) || (a.title || '').localeCompare(b.title || '');
    });
    clear(box).append(...members.map((m) => {
      const avatar = el('span', { class: `avatar avatar--sm accent-${m.color}` });
      fillAvatar(avatar, { id: m.userId, title: m.title, avatar: m.avatar, avatarThumb: m.avatarThumb });
      return el('button', {
        class: 'info-panel__member', type: 'button',
        onclick: () => emit('ui:open-contact', { userId: m.userId }),
      },
      avatar,
      el('span', { class: 'info-panel__member-text' },
        el('span', { class: 'info-panel__member-name' }, m.title || m.username || '(no name)'),
        el('span', { class: 'info-panel__label' }, statusText(m))),
      m.role ? el('span', { class: 'info-panel__role' }, m.role) : null);
    }));
  } catch (error) {
    clear(box);
    hooks.report(error);
  }
}

// ------------------------------------------------------------ gifts
// Подарки профиля (gifts.list — getReceivedGifts): сетка стикеров с ценой
// и отправителем, фильтр по виду (как у нативного клиента: все,
// ограниченные, неограниченные, уникальные) и сортировка по цене.
// Открывается строкой «N gifts» в панели и кнопкой Gifts в шапке чата.
const GIFT_KINDS = [['all', 'All'], ['limited', 'Limited'], ['unlimited', 'Unlimited'], ['unique', 'Unique']];

let view = 'info';         // 'info' | 'gifts'
let gifts = { kind: 'all', sortByPrice: false, items: [], next: '', total: 0, loading: false };

function openGifts() {
  view = 'gifts';
  gifts = { kind: gifts.kind, sortByPrice: gifts.sortByPrice, items: [], next: '', total: 0, loading: false };
  if (!open) setOpen(true);
  loadGifts(true);
}

// Свой счётчик запросов подарков. Раньше ответ сверялся со счётчиком
// запросов СВЕДЕНИЙ (asked): переход в другой чат перечитывал сведения,
// ответ с подарками выбрасывался как устаревший, а выход мимо перерисовки
// оставлял «Loading gifts…» навсегда (живой случай: подарок → отправитель
// → его подарки).
let giftsSeq = 0;

async function loadGifts(fresh) {
  if (!info) return;
  // «Ещё» ждёт идущую загрузку; новая (фильтр, другой чат) её перебивает.
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
    if (my !== giftsSeq) return;   // перебит новой загрузкой — она и нарисует
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

/** Подробности подарка — окно поверх, как у нативного клиента. */
function giftDetails(g) {
  const dialog = el('dialog', { class: 'confirm gift-details' });
  const rows = [];
  const row = (label, value) => {
    if (value) rows.push(el('div', { class: 'gift-details__row' },
      el('span', { class: 'gift-details__label' }, label),
      typeof value === 'string' ? el('span', {}, value) : value));
  };
  // Отправитель — ссылкой: личка с человеком или сам канал.
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
  // Нативный append, в отличие от el(), null не пропускает — он стал бы
  // текстом «null». Поэтому только то, что есть.
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
    onclick: () => { view = 'info'; render(); },
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
    // Кто подарил — кружок в углу, как у нативного клиента.
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

// ----------------------------------------------------------- render
function render() {
  const i = info;
  if (!i) return;
  if (view === 'gifts') {
    renderGifts();
    return;
  }
  const avatar = el('span', { class: `avatar info-panel__avatar accent-${i.color}` });
  fillAvatar(avatar, {
    id: i.chatId, title: i.title, avatar: i.avatar, avatarThumb: i.avatarThumb, avatarAnim: i.avatarAnim,
  });

  const head = el('div', { class: 'info-panel__head' },
    el('button', {
      class: 'info-panel__avatar-btn', type: 'button',
      title: i.userId ? 'Photos' : '', onclick: () => openPhotos(i),
    }, avatar),
    el('div', { class: 'info-panel__title' }, i.title || ''),
    el('div', {
      class: `info-panel__status${i.status === 'userStatusOnline' ? ' is-online' : ''}`,
    }, statusLine(i)));

  const more = actionButton('dots', 'More', (event) => {
    const items = actions(i).map(([label, run]) => ({ label, onSelect: run }));
    if (items.length) openMenu(event.currentTarget, items);
  });
  const buttons = el('div', { class: 'info-panel__actions' },
    actionButton('chat', 'Chat', () => {
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
    actionButton('mic', 'Call', () => hooks.notice('Calls are not supported in this app yet')),
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
      onclick: () => emit('ui:set-filter', filter),
    }, icon(iconName), el('span', {}, `${n} ${label}`)));
  }

  const parts = [head, buttons];
  if (rows.length) parts.push(el('section', { class: 'info-panel__section' }, ...rows));
  if (counts.length) parts.push(el('section', { class: 'info-panel__section' }, ...counts));

  if ((i.kind === 'group') && i.canGetMembers) {
    const box = el('div', { class: 'info-panel__members' },
      el('p', { class: 'info-panel__hint' }, 'Loading members…'));
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
  clear(body).append(...parts);
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
  box.append(toggle, panel);
  // Кнопка Gifts в шапке чата (ui/chat-header.js).
  on('ui:open-gifts', async () => {
    if (store.activeChatId === null) return;
    if (!open || !info || info.chatId !== store.activeChatId) {
      view = 'info';
      setOpen(true);
      // Подарки просятся от имени владельца из chat.info — ждём его.
      const wait = () => new Promise((resolve) => setTimeout(resolve, 100));
      for (let n = 0; n < 50 && (!info || info.chatId !== store.activeChatId); n += 1) await wait();
    }
    if (info) openGifts();
  });

  on('store:active', () => {
    toggle.hidden = store.activeChatId === null;
    if (store.activeChatId === null) setOpen(false);
    else if (open) load();
  });
  // Вступили, вышли, заблокировали, переименовали — список чатов меняется;
  // открытая панель перечитывается, но не чаще, чем раз в несколько секунд.
  let last = 0;
  on('srv:chats', () => {
    if (!open || loadingFor !== null || Date.now() - last < 5000) return;
    last = Date.now();
    load();
  });
}
