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

// Панель информации о чате — человек, бот, группа или канал. Открывается
// кнопкой «i» в правом верхнем углу истории и выезжает справа поверх неё
// (не как у официального клиента — по просьбе пользователя).
//
// Что внутри, повторяет нативный клиент: аватарка (у людей — галерея их
// фото), имя и статус, кнопки Chat / Mute / Call / More, телефон, «о себе»,
// имя пользователя, день рождения, описание и ссылка группы, счётчики
// медиа (сеткой или списком здесь же), подарки,
// участники группы и действия: поделиться контактом, добавить / изменить /
// удалить контакт, заблокировать, выйти из группы.
//
// Данные — мост: chat.info, chat.members, info.action (webapi.pas).

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'];

// Счётчики медиа: ключ из chat.info, подпись и фильтр истории (тот же, что
// у кнопок в шапке чата — FILTERS в ui/chat-header.js). '@вид' — не
// фильтр, а сетка или список здесь же, в панели (openMedia).
const COUNTS = [
  ['photo', 'image', 'photos', '@photo'],
  ['video', 'video', 'videos', '@video'],
  ['document', 'file', 'files', '@file'],
  ['audio', 'audio', 'audio files', '@audio'],
  ['url', 'link', 'links', '@link'],
  ['voice', 'mic', 'voice messages', '@voice'],
  ['animation', 'gif', 'GIFs', '@gif'],
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
  if (!on) setView('info');
  panel.classList.toggle('is-open', on);
  toggle.classList.toggle('is-active', on);
  toggle.setAttribute('aria-expanded', String(on));
  if (on) load();
}

// Чат, сведения о котором показаны, если это НЕ открытый чат: «Contact
// info» из меню сообщения (ui:contact-info) — личка с отправителем.
// Сбрасывается сменой открытого чата.
let override = null;
const viewChatId = () => override ?? store.activeChatId;

/** Показать сведения о другом чате, не открывая его (ui:contact-info). */
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
    // Другой чат — подарки и медиа прежнего ни к чему (сетка, открытая
    // уже для этого чата кнопкой в шапке, остаётся).
    if (info && info.chatId !== chatId && !(view === 'media' && media.chatId === chatId)) setView('info');
    // Мост называет личку 'private' (и 'secret' — секретный чат), как
    // список чатов (ChatKindStr); панели это один вид — человек. Без этого
    // у контактов не было ни действий, ни меню More.
    if (next.kind === 'private' || next.kind === 'secret') next.kind = 'user';
    info = next;
    // На подарках и медиа фоновое обновление сведений сетку не
    // перестраивает: она от них не зависит, а перестройка заново
    // запускала стикеры и не давала разглядеть элементы в инспекторе.
    if (view !== 'info') return;
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

/**
 * Telegram ID под именем: у человека — user id, у группы и канала — id
 * чата (-100…, как его видят боты). Клик — в буфер обмена.
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

// host — аватарка, по которой кликнули: account.photos ждёт, пока все
// фото докачаются (на длинной истории — секунды), и всё это время вокруг
// неё крутится кольцо (.is-ring-loading, components/_spinner.scss).
// Повторный клик, пока кольцо крутится, второй запрос не шлёт.
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

let view = 'info';         // 'info' | 'gifts' | 'media'
let gifts = { kind: 'all', sortByPrice: false, items: [], next: '', total: 0, loading: false };

/** Смена вида; шапке чата — какая сетка медиа открыта (подсветка кнопки). */
function setView(next) {
  const was = view === 'media' ? media.filter : '';
  if (view === 'media' && next !== 'media') {
    mediaSeq += 1;      // ответ идущей загрузки больше некуда дописывать
    mediaParts = null;
    if (mediaFloat) mediaFloat.hidden = true;
  }
  view = next;
  const now = view === 'media' ? media.filter : '';
  if (was !== now) emit('info:media-view', now);
}

function openGifts() {
  setView('gifts');
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
    onclick: () => { setView('info'); render(); },
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

// ------------------------------------------------------------ media
// Медиа чата в панели, как у нативного клиента (media.list —
// searchChatMessages с фильтром): фото, видео и GIF — сеткой квадратных
// превью, музыка, ссылки, голосовые, файлы и закреплённые — списком строк. Клик по плитке или строке
// панель не закрывает: история прокручивается к этому сообщению
// (ui:open-source), и можно идти дальше. Следующая страница подгружается,
// когда прокрутка панели подходит к концу; новое дописывается в конец,
// уже показанное не перестраивается.
//
// Вид: ключ, подпись кнопки, подпись счётчика, пустой список, раскладка.
const MEDIA_KINDS = [
  ['photo', 'Photos', 'photos', 'No photos here.', 'grid'],
  ['video', 'Videos', 'videos', 'No videos here.', 'grid'],
  ['gif', 'GIFs', 'GIFs', 'No GIFs here.', 'grid'],
  ['audio', 'Music', 'audio files', 'No music here.', 'list'],
  ['link', 'Links', 'links', 'No links here.', 'list'],
  ['voice', 'Voice', 'voice messages', 'No voice messages here.', 'list'],
  ['file', 'Files', 'files', 'No files here.', 'list'],
  ['pinned', 'Pinned', 'pinned messages', 'No pinned messages.', 'list'],
];
// За сколько пикселей до конца прокрутки просить следующую страницу.
const MEDIA_PRELOAD_PX = 400;
// Цвета буквы-заглушки у ссылки без картинки — запасная палитра (f0..f7,
// как у отправителей без своего цвета).
const MEDIA_LETTER_COLORS = 8;

let media = { filter: 'photo', chatId: null, items: [], next: 0, total: 0, loading: false, done: false };
let mediaParts = null;     // { title, grid, foot } — узлы открытого вида
// Дни, как в истории: разделитель на каждый новый день и плавающий
// ярлык поверх прокрутки (util/floatdate.js). mediaDay — день последнего
// дописанного элемента, чтобы следующая страница продолжила разбиение.
let mediaDay = '';
let mediaFloat = null;
// Отступ ярлыка от верха панели — top у .info-panel__float-date.
const MEDIA_FLOAT_TOP = 16;
let mediaSeq = 0;          // свой счётчик запросов, как у подарков
let mediaCurrent = null;   // плитка или строка, к сообщению которой ушла история

function mediaKind() {
  return MEDIA_KINDS.find(([k]) => k === media.filter) ?? MEDIA_KINDS[0];
}

function openMedia(filter) {
  media = { filter, chatId: viewChatId(), items: [], next: 0, total: 0, loading: false, done: false };
  mediaCurrent = null;
  setView('media');
  // Смена вида внутри медиа (Photos -> Music) view не меняет — шапке
  // сообщаем сами.
  emit('info:media-view', filter);
  if (!open) setOpen(true);
  renderMedia();
  loadMedia(true);
}

async function loadMedia(fresh) {
  if (!fresh && (media.loading || media.done)) return;
  const my = ++mediaSeq;
  const { chatId, filter } = media;
  media.loading = true;
  mediaFoot();
  try {
    const r = await hooks.call('media.list', { chatId, filter, from: fresh ? 0 : media.next });
    if (my !== mediaSeq) return;   // перебит — другой вид или другой чат
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
  // Страница не заполнила панель — прокрутки не будет, просим следующую.
  mediaMaybeMore();
}

function mediaTitle() {
  const [, label, plural] = mediaKind();
  return media.total ? `${media.total} ${plural}` : label;
}

/** Перейти к сообщению в истории; плитка или строка отмечается. */
function mediaGo(node, item) {
  mediaCurrent?.classList.remove('is-current');
  mediaCurrent = node;
  node.classList.add('is-current');
  emit('ui:open-source', { chatId: media.chatId, messageId: item.id });
}

function realUrl(item) {
  return item.url && item.url !== '-' ? item.url : '';
}

/** Превью: картинка или беззвучный ролик (MPEG4-превью у GIF и видео). */
function mediaPreview(item, cls) {
  const url = realUrl(item);
  if (!url) return null;
  if (item.thumbKind !== 'video') return el('img', { class: cls, src: url, alt: '', loading: 'lazy' });
  const video = el('video', { class: cls, src: url, loop: true, playsinline: true, preload: 'metadata' });
  video.muted = true;
  return video;
}

/**
 * Элементы с разделителями дней — та же разметка, что у истории
 * (.history__date с data-day), чтобы и вид, и плавающий ярлык были
 * одни. В сетке разделитель занимает весь ряд (.media-day).
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
  if (item.kind === 'pinned') return pinnedRow(item);
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
  // Подложка — размытая minithumbnail, пока превью нет (или не скачалось).
  item.thumb ? el('img', { class: 'media-tile__blur', src: item.thumb, alt: '' }) : null,
  preview,
  item.kind === 'video'
    ? el('span', { class: 'media-tile__badge' }, icon('play', 'icon--sm'),
      item.duration ? duration(item.duration) : null)
    : null,
  item.kind === 'gif' ? el('span', { class: 'media-tile__badge' }, 'GIF') : null);
  // Ролик-превью оживает под мышью, как у нативного клиента: два десятка
  // играющих разом в одной панели ни к чему.
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

/** Квадрат-заглушка с буквами; цвет — от текста, стабильный (f0..f7). */
function letterTile(text, label) {
  let hash = 0;
  for (const ch of text) hash = (hash * 31 + ch.codePointAt(0)) >>> 0;
  const long = typeof label === 'string' && label.length > 1;
  return el('span', { class: `media-row__letter accent-f${hash % MEDIA_LETTER_COLORS}${long ? ' is-ext' : ''}` }, label);
}

/** Голосовое: аватарка отправителя, его имя, длительность; дата справа. */
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

/** Закреплённое: картинка сообщения или аватарка отправителя, имя, текст. */
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

/** Файл: превью или расширение на цветном квадрате, имя, размер; дата справа. */
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

/** Адреса сообщения без повторов: сущности текста, иначе адрес предпросмотра. */
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
    // Буква сайта на цветном квадрате; цвет — от имени сайта, стабильный.
    const name = p?.siteName || host;
    pic = letterTile(name, initial(name));
  }
  // В строке есть ссылки — кнопкой её не сделать (ссылка внутри кнопки
  // недопустима), поэтому div с ролью кнопки и Enter с клавиатуры.
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
      // Ссылка открывается сама (t.me — внутри приложения, ui/links.js);
      // переход к сообщению строке при этом не нужен.
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
    onclick: () => { setView('info'); render(); },
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
      // Сведения о чужом контакте — открыть личку с ним.
      if (override !== null && override !== store.activeChatId) {
        const id = override;
        setOpen(false);
        setActiveChat(id);
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
    // Звонок: человеку — личный (ui/call.js), голосом или с видео;
    // группе и каналу — видеочат (ui/videochat.js).
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
  // Панель перестраивается целиком (в том числе по srv:chats, пока
  // открыта), и кнопка, под которой открыто меню (Call, More), заменяется
  // новой. Меню без якоря не закрывается, а падает в угол экрана —
  // поэтому якорь переносится на новую кнопку с той же подписью
  // (reanchorMenu ничего не делает, если меню открыто не от неё).
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
  // Плавающая дата медиа — поверх тела панели, как у истории.
  mediaFloat = el('div', { class: 'history__float-date info-panel__float-date', hidden: true }, el('span'));
  panel.append(mediaFloat);
  box.append(toggle, panel);
  // «Contact info» из меню сообщения: личка с отправителем
  // (createPrivateChat — bot.userChat) и её сведения.
  on('ui:contact-info', async ({ userId }) => {
    try {
      const r = await hooks.call('bot.userChat', { userId: String(userId) });
      if (r?.chatId) openInfoFor(r.chatId);
    } catch (error) {
      hooks.report(error);
    }
  });
  // Аватарка в шапке чата: у человека — галерея его фото, у группы и
  // канала (истории аватарок у них нет) — сама панель.
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
  // Кнопка Gifts в шапке чата (ui/chat-header.js).
  // Кнопки медиа в шапке чата (Photos … Files): сетка или список,
  // повторный клик — закрыть.
  on('ui:open-media', (filter) => {
    if (store.activeChatId === null) return;
    if (open && view === 'media' && media.filter === filter && media.chatId === store.activeChatId) {
      setView('info');
      mediaParts = null;
      render();
      return;
    }
    openMedia(filter);
  });
  on('ui:open-gifts', async () => {
    if (store.activeChatId === null) return;
    if (!open || !info || info.chatId !== store.activeChatId) {
      setView('info');
      setOpen(true);
      // Подарки просятся от имени владельца из chat.info — ждём его.
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
  // Вступили, вышли, заблокировали, переименовали — список чатов меняется;
  // открытая панель перечитывается, но не чаще, чем раз в несколько секунд.
  let last = 0;
  on('srv:chats', () => {
    if (!open || loadingFor !== null || Date.now() - last < 5000) return;
    last = Date.now();
    load();
  });
}
