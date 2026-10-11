import { el, append } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { fillAvatar } from '../util/avatar.js';

// Ссылки Telegram (t.me, telegram.me, telegram.dog, tg:) открываются
// здесь, а не в браузере.
//
// Что за ссылка — решает TDLib (link.resolve в webapi.pas): публичный
// чат, приглашение, ссылка на сообщение. Чат открывается, сообщение —
// ещё и прокручивается к себе (ui:open-source, тот же путь, что у
// перехода по пересылке). Приглашение в чат, где доступа ещё нет, —
// вопрос «Join?». Всё, чего приложение не умеет (боты, наборы стикеров,
// прокси…), уходит в браузер, как раньше.

const TELEGRAM_LINK = /^(?:https?:\/\/(?:www\.)?(?:t\.me|telegram\.me|telegram\.dog)\/|tg:)/i;

let hooks = {};

function openOutside(href) {
  // Окно WebView2 отдаёт новое окно системе (NewWindowRequested).
  window.open(href, '_blank', 'noopener');
}

/**
 * Описание чата: переносы строк сохраняются (стилем), а @упоминания —
 * ссылки на t.me, которые открываются здесь же, тем же путём.
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
 * «Вступить?» — содержимое как у окна нативного клиента: аватарка,
 * название, число подписчиков, описание, а у чатов по заявкам —
 * пояснение, что вступить можно только после одобрения. Окно — то же
 * подтверждение, что у удаления (blocks/_confirm.scss).
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
      // Клик мимо окна — отмена. (Ссылки в описании закрывают окно сами,
      // в mountLinks: сюда их клик не доходит.)
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
  // Ссылка-счёт (t.me/$имя) — оплата здесь же (ui/bots.js payInvoice).
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
 * Открыть ссылку так же, как по клику в тексте: t.me — внутри
 * приложения, прочее — в браузере. Для кнопок ботов (ui/bots.js).
 */
export function openLink(href) {
  if (!href) return;
  if (TELEGRAM_LINK.test(href)) follow(href).catch(console.error);
  else openOutside(href);
}

/** hooks: { call(cmd, args), openChat(id), openMessage(chatId, messageId), report(err), notice(text) } */
export function mountLinks(options) {
  hooks = options ?? {};
  // В фазе перехвата: раньше, чем ссылка уйдёт по target=_blank, и
  // раньше обработчиков самих сообщений.
  document.addEventListener('click', (event) => {
    if (event.button !== 0 || event.defaultPrevented) return;
    const a = event.target.closest?.('a[href]');
    if (!a || !TELEGRAM_LINK.test(a.href)) return;
    event.preventDefault();
    event.stopPropagation();
    // Ссылка из окна (упоминание в описании канала) — окно закрывается:
    // переходим туда. Само окно этого клика не увидит — его останавливает
    // stopPropagation строкой выше, ещё на уровне документа.
    a.closest('dialog')?.close();
    follow(a.href).catch(console.error);
  }, true);
}
