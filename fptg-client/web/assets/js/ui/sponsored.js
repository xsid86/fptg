import { el, clear, append } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store } from '../core/store.js';
import { icon } from '../util/icons.js';
import { openMenu } from '../util/menu.js';
import { fillAvatar } from '../util/avatar.js';
import { renderRichText } from '../util/entities.js';
import { setCustomEmoji } from '../util/emoji.js';
import { openLink } from './links.js';

// Official Telegram ads (Telegram API ToS 3.3,
// core.telegram.org/api/sponsored-messages): in a channel — cards after the
// last post, in a chat with a bot — an "Ad" bar above the input field.
//
// What to show is decided by the bridge (ads.get in webapi.pas): it asks
// getChatSponsoredMessages on every opening of a channel or bot (keeps the
// answer for 5 minutes), downloads the media and returns it ready to show.
// A view (ads.view) — once, when the whole ad text is on screen; a click
// (ads.click) — the button, the title, the avatar, the media or a link in
// the text; a report (ads.report) — with the options Telegram sends.

const TELEGRAM_LINK = /^(?:https?:\/\/(?:www\.)?(?:t\.me|telegram\.me|telegram\.dog)\/|tg:)/i;

let hooks = {};
let bar = null;
// chatId -> the ads.get answer ({ chatId, between, items })
const ads = new Map();
// `${chatId}:${id}` of views already counted
const viewed = new Set();
// Card nodes: the history reconciles nodes by identity, so the card of the
// same ad is the same node.
const cards = new Map();
let observer = null;
let barObserver = null;
// The ad the bar is showing now (for its context menu).
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
 * The channel's ads for the history: { between, items } or null. A comment
 * thread and search show no ads — the history decides that.
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
    // Ads are not what the chat was opened for: the error only to the console.
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

// ------------------------------------------------------------- click
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

/** The sponsor's link: t.me — inside the app, the rest — after a question. */
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

// ------------------------------------------------------- menu and report
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

/** Choosing a report option; resolves to the option id or null. */
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
  // Telegram may ask for clarification several times in a row.
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

// -------------------------------------------------------------- views
/**
 * A view counts when the whole text is on screen (the button does not count
 * — so in td_api.tl for viewMessages). A text taller than the window will
 * not fit whole: then it is enough that it filled the window's height.
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

// ------------------------------------------------------------ markup
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
  // A link in the text is an ad click too. pointerdown, not click: t.me
  // links are intercepted by ui/links.js in the capture phase on the
  // document, and their click does not reach this node.
  text.addEventListener('pointerdown', (event) => {
    if (event.button === 0 && event.target.closest('a[href]')) reportClick(ad);
  });
  // A link outside Telegram — only after a question.
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

/** A channel ad card — for the history, after the posts. */
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

/** The ad bar in a chat with a bot; null — remove it. */
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
