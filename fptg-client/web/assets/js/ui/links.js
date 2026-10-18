import { el, append } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { fillAvatar } from '../util/avatar.js';

// Telegram links (t.me, telegram.me, telegram.dog, tg:) open here, not in
// the browser.
//
// What the link is — TDLib decides (link.resolve in webapi.pas): a public
// chat, an invite, a message link. The chat opens, a message — also
// scrolls to itself (ui:open-source, the same path as following a
// forward). An invite to a chat with no access yet — the question "Join?".
// Everything the app cannot do (bots, sticker sets, proxies…) goes to the
// browser, as before.

const TELEGRAM_LINK = /^(?:https?:\/\/(?:www\.)?(?:t\.me|telegram\.me|telegram\.dog)\/|tg:)/i;

let hooks = {};

function openOutside(href) {
  // The WebView2 window hands a new window to the system (NewWindowRequested).
  window.open(href, '_blank', 'noopener');
}

/**
 * A chat description: line breaks are kept (by a style), and @mentions —
 * t.me links that open right here, the same way.
 */
function descriptionNodes(text) {
  const parts = [];
  const mention = /@([A-Za-z0-9_]{4,32})/g;
  let at = 0;
  for (const m of text.matchAll(mention)) {
    if (m.index > at) parts.push(text.slice(at, m.index));
    parts.push(el('a', { href: `https://t.me/${m[1]}` }, m[0]));
    at = m.index + m[0].length;
  }
  if (at < text.length) parts.push(text.slice(at));
  return parts;
}

/**
 * "Join?" — the content as in the native client's window: the avatar, the
 * title, the subscriber count, the description, and for chats by request —
 * a note that one can join only after approval. The window is the same
 * confirmation as for deletion (blocks/_confirm.scss).
 */
function askJoin(invite) {
  return new Promise((resolve) => {
    const what = invite.channel ? 'subscribers' : 'members';
    const dialog = el('dialog', { class: 'confirm confirm--invite', 'aria-label': 'Join chat' });
    let answer = false;
    const close = () => dialog.close();

    let label = invite.channel ? 'Subscribe' : 'Join';
    if (invite.request) label = 'Request to join';
    const join = el('button', {
      class: 'btn confirm__button', type: 'button',
      onclick: () => { answer = true; close(); },
    }, label);

    const avatar = el('span', { class: `avatar confirm__avatar accent-${invite.color || 'f0'}` });
    fillAvatar(avatar, { title: invite.title || '?', avatar: invite.avatar, avatarThumb: invite.avatarThumb });

    const admins = invite.channel ? 'channel' : 'group';
    append(dialog, [
      avatar,
      el('h2', { class: 'confirm__title' }, invite.title || 'Chat'),
      invite.members
        ? el('p', { class: 'confirm__count' },
          `${new Intl.NumberFormat().format(invite.members)} ${what}`)
        : null,
      invite.description
        ? el('p', { class: 'confirm__description' }, ...descriptionNodes(invite.description))
        : null,
      invite.request
        ? el('p', { class: 'confirm__note confirm__note--center' },
          `New ${what} can join only after the ${admins} admins approve the request.`)
        : null,
      el('div', { class: 'confirm__buttons' },
        el('button', { class: 'btn confirm__button', type: 'button', onclick: close }, 'Cancel'),
        join)]);

    dialog.addEventListener('click', (event) => {
      // A click outside the window — a cancel. (Links in the description
      // close the window themselves, in mountLinks: their click does not reach here.)
      if (event.target === dialog) close();
    });
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(answer);
    });
    document.body.append(dialog);
    dialog.showModal();
    join.focus();
  });
}

async function follow(href) {
  let target;
  try {
    target = await hooks.call('link.resolve', { url: href });
  } catch (error) {
    hooks.report(error);
    return;
  }
  if (target?.external) {
    openOutside(href);
    return;
  }
  // An invoice link (t.me/$name) — payment right here (ui/bots.js payInvoice).
  if (target?.invoice) {
    emit('ui:pay-invoice', { invoiceName: target.invoice });
    return;
  }
  if (target?.invite) {
    if (!(await askJoin(target.invite))) return;
    let joined;
    try {
      joined = await hooks.call('link.join', { link: target.invite.link });
    } catch (error) {
      hooks.report(error);
      return;
    }
    if (joined?.requested) {
      hooks.notice('Join request sent');
      return;
    }
    if (!joined?.chatId) return;
    target = joined;
  }
  if (!target?.chatId) return;
  if (target.messageId) hooks.openMessage(target.chatId, target.messageId);
  else hooks.openChat(target.chatId);
}

/**
 * Open a link the same way as on a click in the text: t.me — inside the
 * app, the rest — in the browser. For bot buttons (ui/bots.js).
 */
export function openLink(href) {
  if (!href) return;
  if (TELEGRAM_LINK.test(href)) follow(href).catch(console.error);
  else openOutside(href);
}

/** hooks: { call(cmd, args), openChat(id), openMessage(chatId, messageId), report(err), notice(text) } */
export function mountLinks(options) {
  hooks = options ?? {};
  // In the capture phase: before the link goes off via target=_blank, and
  // before the messages' own handlers.
  document.addEventListener('click', (event) => {
    if (event.button !== 0 || event.defaultPrevented) return;
    const a = event.target.closest?.('a[href]');
    if (!a || !TELEGRAM_LINK.test(a.href)) return;
    event.preventDefault();
    event.stopPropagation();
    // A link from a window (a mention in a channel description) — the
    // window closes: we go there. The window itself will not see this click
    // — stopPropagation a line above stops it, still at the document level.
    a.closest('dialog')?.close();
    follow(a.href).catch(console.error);
  }, true);
}
