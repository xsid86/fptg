import { el, clear, append } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store } from '../core/store.js';
import { icon } from '../util/icons.js';
import { openMenu } from '../util/menu.js';
import { fillAvatar } from '../util/avatar.js';
import { renderRichText } from '../util/entities.js';
import { setCustomEmoji } from '../util/emoji.js';
import { openLink } from './links.js';

// Официальная реклама Telegram (Telegram API ToS 3.3,
// core.telegram.org/api/sponsored-messages): в канале — карточки после
// последнего поста, в чате с ботом — полоса «Ad» над полем ввода.
//
// Что показывать, решает мост (ads.get в webapi.pas): он спрашивает
// getChatSponsoredMessages при каждом открытии канала или бота (у себя
// держит ответ 5 минут), докачивает медиа и отдаёт уже готовое к показу.
// Показ (ads.view) — один раз, когда весь текст рекламы на экране; клик
// (ads.click) — кнопка, заголовок, аватарка, медиа или ссылка в тексте;
// жалоба (ads.report) — с вариантами, которые присылает Telegram.

const TELEGRAM_LINK = /^(?:https?:\/\/(?:www\.)?(?:t\.me|telegram\.me|telegram\.dog)\/|tg:)/i;

let hooks = {};
let bar = null;
// chatId -> ответ ads.get ({ chatId, between, items })
const ads = new Map();
// `${chatId}:${id}` уже засчитанных показов
const viewed = new Set();
// Узлы карточек: история сверяет узлы по тождеству, поэтому карточка
// одной и той же рекламы — один и тот же узел.
const cards = new Map();
let observer = null;
let barObserver = null;
// Реклама, которую сейчас показывает полоса (для её контекстного меню).
let barAd = null;

const key = (ad) => `${ad.chatId}:${ad.id}`;

/** hooks: { call(cmd, args), report(err), notice(text) } */
export function mountSponsored(composer, options) {
  hooks = options ?? {};
  bar = el('aside', { class: 'ad-bar', hidden: true, 'aria-label': 'Ad' });
  composer.before(bar);
  bar.addEventListener('contextmenu', (event) => {
    if (!barAd) return;
    event.preventDefault();
    openAdMenu(bar, barAd, { x: event.clientX, y: event.clientY });
  });
  on('store:active', () => load(store.activeChatId));
}

/**
 * Реклама канала для истории: { between, items } или null. Ветка
 * комментариев и поиск рекламы не показывают — это решает история.
 */
export function channelAds(chatId) {
  const data = ads.get(chatId);
  return data?.items?.length ? data : null;
}

async function load(chatId) {
  renderBar(null);
  if (chatId === null || chatId === undefined) return;
  let data;
  try {
    data = await hooks.call('ads.get', { chatId: String(chatId) });
  } catch (error) {
    // Реклама — не то, ради чего открыт чат: ошибка только в консоль.
    console.error(error);
    return;
  }
  if (store.activeChatId !== chatId) return;
  if (data?.customEmoji) setCustomEmoji(data.customEmoji);
  ads.set(chatId, data ?? { items: [] });
  if (data?.kind === 'bot') renderBar(data.items?.[0] ?? null);
  else emit('ui:ads');
}

function forget(chatId) {
  ads.delete(chatId);
  if (store.activeChatId === chatId) {
    renderBar(null);
    emit('ui:ads');
  }
}

// ------------------------------------------------------------- клик
function confirmOutside(url) {
  return new Promise((resolve) => {
    const dialog = el('dialog', { class: 'confirm', 'aria-label': 'Open link' });
    let answer = false;
    const open = el('button', {
      class: 'btn confirm__button', type: 'button',
      onclick: () => { answer = true; dialog.close(); },
    }, 'Open');
    append(dialog, [
      el('p', { class: 'confirm__text' }, 'Open this link?'),
      el('p', { class: 'confirm__note ad-link' }, url),
      el('div', { class: 'confirm__buttons' },
        el('button', { class: 'btn confirm__button', type: 'button', onclick: () => dialog.close() }, 'Cancel'),
        open)]);
    dialog.addEventListener('click', (event) => {
      if (event.target === dialog) dialog.close();
    });
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(answer);
    });
    document.body.append(dialog);
    dialog.showModal();
    open.focus();
  });
}

function reportClick(ad, media = false) {
  hooks.call('ads.click', {
    chatId: String(ad.chatId), id: String(ad.id), media, fullscreen: false,
  }).catch(console.error);
}

/** Ссылка спонсора: t.me — внутри приложения, прочее — после вопроса. */
async function follow(url) {
  if (!url) return;
  if (TELEGRAM_LINK.test(url)) {
    openLink(url);
    return;
  }
  if (await confirmOutside(url)) window.open(url, '_blank', 'noopener');
}

function activate(ad, media = false) {
  reportClick(ad, media);
  follow(ad.url);
}

// ------------------------------------------------------- меню и жалоба
function showInfo(ad) {
  const dialog = el('dialog', { class: 'confirm', 'aria-label': 'Sponsor info' });
  const ok = el('button', {
    class: 'btn confirm__button', type: 'button', onclick: () => dialog.close(),
  }, 'OK');
  append(dialog, [
    el('p', { class: 'confirm__text' }, 'Sponsor info'),
    ad.sponsorInfo ? el('p', { class: 'confirm__note confirm__note--plain' }, ad.sponsorInfo) : null,
    ad.additionalInfo ? el('p', { class: 'confirm__note confirm__note--plain' }, ad.additionalInfo) : null,
    el('div', { class: 'confirm__buttons' }, ok)]);
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) dialog.close();
  });
  dialog.addEventListener('close', () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
  ok.focus();
}

/** Выбор варианта жалобы; resolve — id варианта или null. */
function chooseOption(title, options) {
  return new Promise((resolve) => {
    const dialog = el('dialog', { class: 'confirm', 'aria-label': 'Report ad' });
    let answer = null;
    const list = el('div', { class: 'ad-report' });
    for (const option of options) {
      list.append(el('button', {
        class: 'btn ad-report__option', type: 'button',
        onclick: () => { answer = option.id; dialog.close(); },
      }, option.text));
    }
    append(dialog, [
      el('p', { class: 'confirm__text' }, title || 'Report ad'),
      list,
      el('div', { class: 'confirm__buttons' },
        el('button', { class: 'btn confirm__button', type: 'button', onclick: () => dialog.close() }, 'Cancel'))]);
    dialog.addEventListener('click', (event) => {
      if (event.target === dialog) dialog.close();
    });
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(answer);
    });
    document.body.append(dialog);
    dialog.showModal();
  });
}

async function report(ad) {
  let option = '';
  // Telegram может спрашивать уточнение несколько раз подряд.
  for (;;) {
    let res;
    try {
      res = await hooks.call('ads.report', { chatId: String(ad.chatId), id: String(ad.id), option });
    } catch (error) {
      hooks.report?.(error);
      return;
    }
    switch (res?.result) {
      case 'options': {
        const picked = await chooseOption(res.title, res.options ?? []);
        if (picked === null) return;
        option = picked;
        continue;
      }
      case 'ok':
        hooks.notice?.('The ad has been reported');
        forget(ad.chatId);
        return;
      case 'hidden':
        hooks.notice?.('Ads are hidden');
        ads.clear();
        forget(ad.chatId);
        return;
      case 'premium':
        hooks.notice?.('Hiding ads requires Telegram Premium');
        return;
      default:
        hooks.notice?.('This ad can no longer be reported');
        return;
    }
  }
}

function openAdMenu(anchor, ad, at) {
  const items = [];
  if (ad.sponsorInfo || ad.additionalInfo) {
    items.push({ label: 'Sponsor info', onSelect: () => showInfo(ad) });
  }
  if (ad.canReport) items.push({ label: 'Report ad', onSelect: () => report(ad) });
  if (!items.length) return;
  openMenu(anchor, items, at ? { at } : {});
}

// -------------------------------------------------------------- показ
/**
 * Показ засчитывается, когда на экране весь текст (кнопка не в счёт —
 * так в td_api.tl у viewMessages). Текст выше окна целиком не влезет:
 * тогда хватает того, что он занял окно по высоте.
 */
function seen(entries) {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    const box = entry.boundingClientRect;
    const room = entry.rootBounds ? Math.min(box.height, entry.rootBounds.height) : box.height;
    if (entry.intersectionRect.height < room - 1) continue;
    const node = entry.target;
    observer?.unobserve(node);
    barObserver?.unobserve(node);
    const k = node.dataset.adKey;
    if (!k || viewed.has(k)) continue;
    viewed.add(k);
    const [chatId, id] = k.split(':');
    hooks.call('ads.view', { chatId, id }).catch(console.error);
  }
}

const THRESHOLDS = Array.from({ length: 21 }, (_, i) => i / 20);

function watchView(node, inBar) {
  if (viewed.has(node.dataset.adKey)) return;
  if (inBar) {
    barObserver ??= new IntersectionObserver(seen, { threshold: THRESHOLDS });
    barObserver.observe(node);
  } else {
    observer ??= new IntersectionObserver(seen, {
      root: document.getElementById('history'), threshold: THRESHOLDS,
    });
    observer.observe(node);
  }
}

// ------------------------------------------------------------ разметка
function renderMedia(ad) {
  const m = ad.msg?.media;
  if (!m) return null;
  const onclick = () => activate(ad, true);
  if (ad.msg.kind === 'photo') {
    return el('button', { class: 'ad__media', type: 'button', onclick },
      el('img', { class: 'ad__picture', src: m.fullUrl || m.url, alt: '' }));
  }
  if (ad.msg.kind === 'video' || ad.msg.kind === 'animation') {
    return el('button', { class: 'ad__media', type: 'button', onclick },
      el('video', {
        class: 'ad__picture', src: m.url, poster: m.thumbUrl || m.thumb || '',
        muted: true, loop: true, autoplay: true, playsInline: true,
      }));
  }
  return null;
}

function renderText(ad) {
  const text = el('div', { class: 'ad__text', dataset: { adKey: key(ad) } });
  if (ad.title) {
    text.append(el('button', {
      class: 'ad__title', type: 'button', onclick: () => activate(ad),
    }, ad.title));
  }
  if (ad.msg?.text) text.append(renderRichText(ad.msg.text, ad.msg.entities ?? []));
  // Ссылка в тексте — тоже клик по рекламе. pointerdown, а не click:
  // ссылки t.me перехватывает ui/links.js в фазе погружения на
  // документе, и до этого узла их click не доходит.
  text.addEventListener('pointerdown', (event) => {
    if (event.button === 0 && event.target.closest('a[href]')) reportClick(ad);
  });
  // Ссылка не в Telegram — только после вопроса.
  text.addEventListener('click', (event) => {
    const a = event.target.closest('a[href]');
    if (!a || TELEGRAM_LINK.test(a.href)) return;
    event.preventDefault();
    follow(a.href);
  });
  return text;
}

function renderHead(ad) {
  const avatar = el('button', {
    class: 'avatar ad__avatar', type: 'button', title: ad.title || 'Sponsor',
    onclick: () => activate(ad),
  });
  fillAvatar(avatar, { title: ad.title || '?', avatar: ad.avatar });
  const more = (ad.sponsorInfo || ad.additionalInfo || ad.canReport)
    ? el('button', {
      class: 'btn btn--icon ad__more', type: 'button', title: 'More',
      onclick: () => openAdMenu(more, ad),
    }, icon('dots', 'icon--sm'), el('span', { class: 'u-sr-only' }, 'More'))
    : null;
  return el('div', { class: 'ad__head' },
    ad.avatar ? avatar : null,
    el('span', { class: 'ad__label' }, ad.recommended ? 'Recommended' : 'Ad'),
    more);
}

function renderButton(ad) {
  return el('button', {
    class: 'btn ad__button', type: 'button', onclick: () => activate(ad),
  }, ad.buttonText || 'Open');
}

/** Карточка рекламы канала — для истории, после постов. */
export function adCard(ad) {
  const k = key(ad);
  const known = cards.get(k);
  if (known?.ad === ad) return known.node;
  const card = el('article', { class: `ad accent-${ad.color || 'f0'}`, dataset: { adKey: k } });
  card.append(renderHead(ad));
  card.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    openAdMenu(card, ad, { x: event.clientX, y: event.clientY });
  });
  const media = renderMedia(ad);
  if (media) card.append(media);
  const text = renderText(ad);
  card.append(text, renderButton(ad));
  cards.set(k, { ad, node: card });
  watchView(text, false);
  return card;
}

/** Полоса рекламы в чате с ботом; null — убрать. */
function renderBar(ad) {
  if (!bar) return;
  barObserver?.disconnect();
  clear(bar);
  barAd = ad;
  bar.className = 'ad-bar';
  bar.hidden = !ad;
  if (!ad) return;
  bar.classList.add(`accent-${ad.color || 'f0'}`);
  bar.append(renderHead(ad), renderText(ad), renderButton(ad));
  watchView(bar.querySelector('.ad__text'), true);
}
