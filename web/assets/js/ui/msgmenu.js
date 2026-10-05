import { el } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { sideScroll } from '../util/sidescroll.js';
import { openMenu, closeMenu } from '../util/menu.js';
import { copyText } from '../util/clipboard.js';
import { openEmojiPicker } from './picker.js';
import { store } from '../core/store.js';
import { emit } from '../core/bus.js';
import { pickChats, formDialog } from './bots.js';

// The right-click menu on a message, and the row of reactions above it.
//
// WHAT IS OFFERED IS TELEGRAM'S ANSWER, NOT A GUESS. Whether this
// account may edit, delete, pin or forward a particular message is
// messageProperties, and which reactions a chat allows is
// getMessageAvailableReactions - both per message, both able to change
// under the page, and neither cacheable without eventually offering
// something that will be refused. So the menu asks when it opens
// (message.menu) and draws what comes back. Over the loopback socket
// that is a couple of milliseconds; the menu simply appears already
// correct instead of appearing instantly and then lying.
//
// Entries are words, not icons, because that is what every other menu
// in this app is (util/menu.js) - the icon sheet has no glyph for
// delete, edit or forward, and three drawn by hand would look like
// three drawn by hand.

let hooks = {};

/** hooks: { load(cmd,args), act(cmd,args), reply(msg), edit(msg), report(err), notice(text) } */
export function mountMessageMenu(options) {
  hooks = options ?? {};
}

/**
 * One reaction, of either kind.
 *
 * `what` is a character for an ordinary reaction, or
 * { customEmojiId } for a Premium one - which is what the emoji panel
 * answers with when a custom emoji was picked. Telegram decides
 * whether this account may use a custom one; a refusal comes back as
 * an ordinary error rather than being guessed at here.
 */
const react = (msg, what, add) => hooks.act?.('message.react',
  typeof what === 'string'
    ? { id: String(msg.id), emoji: what, add }
    : { id: String(msg.id), customEmojiId: String(what.customEmojiId), add });

/** The emoji this account has already put on the message. */
function mine(msg) {
  return new Set((msg.reactions ?? [])
    .filter((r) => r.chosen && r.kind === 'emoji')
    .map((r) => r.emoji));
}

/**
 * The strip along the top: what the chat offers, with this account's
 * own choices lit, and a chevron that opens the whole emoji panel for
 * anything else.
 *
 * Clicking a reaction that is already lit REMOVES it - one button for
 * both directions, the way it works everywhere else.
 */
function reactionStrip(anchor, msg, info) {
  if (!info.reactions?.length) return null;
  const chosen = mine(msg);

  // All of them, in one line that scrolls. A chat offers far more than
  // a row holds - 13 in a restricted channel, 73 in an ordinary chat,
  // measured - and they used to be cut at eight with no way to reach
  // the rest. Wrapping instead would have turned the menu's header
  // into six rows of emoji.
  const scroller = el('div', { class: 'menu__reactions-scroll' },
    ...info.reactions.map((emoji) => el('button', {
      class: `menu__react${chosen.has(emoji) ? ' is-chosen' : ''}`,
      type: 'button',
      title: chosen.has(emoji) ? 'Remove this reaction' : 'React',
      onclick: () => {
        closeMenu();
        react(msg, emoji, !chosen.has(emoji));
      },
    }, emoji)));
  sideScroll(scroller);

  const row = el('div', { class: 'menu__reactions' }, scroller);

  if (info.allowCustom !== false) {
    // Outside the scroller on purpose: it is a way out of this strip,
    // so it has to stay put while the strip moves under it.
    row.append(el('button', {
      class: 'menu__react menu__react--more',
      type: 'button',
      title: 'Pick any emoji',
      onclick: () => {
        closeMenu();
        // Anchored to the message rather than to this button: the
        // button goes away with the menu, and an anchor that is not in
        // the document positions nothing.
        openEmojiPicker(anchor, (picked) => react(msg, picked, true));
      },
    }, icon('chevron-down')));
  }
  return row;
}

/** Media a message carries, for "Save as". */
function fileOf(msg) {
  const m = msg.media;
  if (!m) return null;
  const url = m.url || m.thumbUrl || null;
  if (!url) return null;
  return { url, name: m.fileName || '' };
}

async function copyLink(msg) {
  try {
    const { url } = await hooks.load('message.link', { id: String(msg.id) });
    await copyText(url);
  } catch (err) {
    hooks.report?.(err);
  }
}

/**
 * Выделенный текст, если выделение лежит в этом сообщении. Берётся ДО
 * запроса message.menu: пока он идёт, выделение ещё то, что видел
 * человек, когда нажимал правую кнопку.
 */
function selectionIn(node) {
  const sel = window.getSelection();
  if (!sel || sel.isCollapsed) return '';
  if (!node.contains(sel.anchorNode) && !node.contains(sel.focusNode)) return '';
  return sel.toString();
}

// Сколько чатов можно выбрать для пересылки за раз.
const FORWARD_MAX = 10;

async function forward(msg) {
  const picked = await pickChats({
    title: 'Forward to', candidates: store.chats, max: FORWARD_MAX,
  });
  if (!picked?.length) return;
  let sent = 0;
  for (const chat of picked) {
    try {
      await hooks.load('message.forward', { id: String(msg.id), toChatId: String(chat.id) });
      sent += 1;
    } catch (err) {
      hooks.report?.(err);
    }
  }
  if (sent) hooks.notice?.(sent === 1 ? 'Message forwarded' : `Forwarded to ${sent} chats`);
}

async function blockSender(msg) {
  const name = msg.senderName || 'this user';
  const yes = await formDialog({
    text: `Block ${name}? They will not be able to message you.`,
    ok: 'Block',
  });
  if (!yes) return;
  try {
    await hooks.load('info.action', { action: 'user.block', userId: String(msg.senderId), block: true });
    hooks.notice?.(`${name} is blocked`);
  } catch (err) {
    hooks.report?.(err);
  }
}

export async function openMessageMenu(anchor, msg, at) {
  const selected = selectionIn(anchor);
  // Отправитель — человек (id чатов отрицательные) и не мы сами.
  const person = !msg.outgoing && Number(msg.senderId) > 0;
  let info;
  try {
    info = await hooks.load('message.menu', { id: String(msg.id) });
  } catch (err) {
    hooks.report?.(err);
    return;
  }

  const items = [];
  // Сервисное сообщение: из всего меню — только удаление.
  if (msg.service) {
    if (info.canDeleteSelf || info.canDeleteAll) {
      items.push({ label: 'Delete', onSelect: () => confirmDelete(msg, info) });
    }
    if (items.length) openMenu(anchor, items, { at });
    return;
  }
  if (info.canReply) {
    items.push({ label: 'Reply', onSelect: () => hooks.reply?.(msg) });
  }
  if (info.canEdit) {
    items.push({ label: 'Edit', onSelect: () => hooks.edit?.(msg) });
  }
  if (info.canPin) {
    items.push({
      label: msg.isPinned ? 'Unpin' : 'Pin',
      onSelect: () => hooks.act?.('message.pin',
        { id: String(msg.id), unpin: Boolean(msg.isPinned) }),
    });
  }
  if (info.canForward) {
    items.push({ label: 'Forward…', onSelect: () => forward(msg) });
  }
  if (selected) {
    items.push({ label: 'Copy selected text', onSelect: () => copyText(selected) });
  }
  if (msg.text) {
    items.push({ label: 'Copy text', onSelect: () => copyText(msg.text) });
  }
  if (info.canGetLink) {
    items.push({ label: 'Copy link', onSelect: () => copyLink(msg) });
  }

  const file = info.canSave ? fileOf(msg) : null;
  if (file) {
    // A plain download link, clicked for the user. The file is already
    // served from the TDLib cache over the same loopback origin, so
    // nothing has to be fetched or re-encoded to save it.
    items.push({
      label: 'Save as…',
      onSelect: () => {
        const a = el('a', { href: file.url, download: file.name || '' });
        document.body.append(a);
        a.click();
        a.remove();
      },
    });
  }

  if (person) {
    if (items.length) items.push('-');
    items.push({
      label: 'Contact info',
      onSelect: () => emit('ui:contact-info', { userId: String(msg.senderId) }),
    });
    items.push({ label: 'Block user', onSelect: () => blockSender(msg) });
  }

  if (info.canDeleteSelf || info.canDeleteAll) {
    if (items.length) items.push('-');
    // Один пункт и подтверждение, как у нативного клиента: у кого
    // пропадёт сообщение — у себя или у всех — решается в диалоге, а не
    // выбором между двумя похожими пунктами без вопроса.
    items.push({
      label: 'Delete',
      onSelect: () => confirmDelete(msg, info),
    });
  }

  if (!items.length && !info.reactions?.length) return;
  openMenu(anchor, items, { header: reactionStrip(anchor, msg, info), at });
}

// ------------------------------------------------------ delete confirm
// Выбор «удалить и у собеседника» с «Remember my choice» — в этом
// браузере: у нативного окна своего такого диалога нет, делить нечего.
const REVOKE_KEY = 'tg.delete.revoke';

function rememberedRevoke() {
  try {
    return window.localStorage.getItem(REVOKE_KEY) === '1';
  } catch {
    return false;
  }
}

function rememberRevoke(on) {
  try {
    window.localStorage.setItem(REVOKE_KEY, on ? '1' : '0');
  } catch { /* приватный режим — просто не запомнится */ }
}

/**
 * Подтверждение удаления. Три вида, по тому, что разрешает сообщение
 * (messageProperties):
 *   * только у себя — вопрос и Cancel / Delete;
 *   * только у всех (супергруппа, канал — revoke там всегда) — вопрос и
 *     пояснение, что удалится у всех;
 *   * и так, и так (личка, свои в обычной группе) — галочка «Also delete
 *     for <собеседник>» (в группе — «for everyone») и «Remember my choice».
 * Модальный <dialog>: Escape и клик мимо — Cancel.
 */
function confirmDelete(msg, info) {
  const chat = store.activeChat;
  const both = info.canDeleteSelf && info.canDeleteAll;
  const personal = ['private', 'bot', 'secret'].includes(chat?.kind);

  const body = [el('p', { class: 'confirm__text' }, 'Delete this message?')];
  let revokeBox = null;
  let rememberBox = null;
  if (both) {
    revokeBox = el('input', { type: 'checkbox', checked: rememberedRevoke() });
    rememberBox = el('input', { type: 'checkbox' });
    body.push(
      el('label', { class: 'confirm__check' }, revokeBox,
        el('span', {}, personal && chat?.title ? `Also delete for ${chat.title}` : 'Also delete for everyone')),
      el('label', { class: 'confirm__check' }, rememberBox, el('span', {}, 'Remember my choice')));
  } else if (info.canDeleteAll) {
    body.push(el('p', { class: 'confirm__note' },
      'This message will be deleted for everyone in this chat.'));
  }

  const dialog = el('dialog', { class: 'confirm', 'aria-label': 'Delete message' });
  const close = () => dialog.close();
  const del = el('button', {
    class: 'btn confirm__button', type: 'button',
    onclick: () => {
      const revoke = both ? revokeBox.checked : !!info.canDeleteAll;
      if (both && rememberBox.checked) rememberRevoke(revokeBox.checked);
      hooks.act?.('message.delete', { id: String(msg.id), revoke });
      close();
    },
  }, 'Delete');
  dialog.append(...body, el('div', { class: 'confirm__buttons' },
    el('button', { class: 'btn confirm__button', type: 'button', onclick: close }, 'Cancel'),
    del));
  // Клик по затемнению вокруг окна — сам <dialog>.
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) close();
  });
  dialog.addEventListener('close', () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
  del.focus();
}

/** Clicking a reaction already on the message toggles this account's own. */
export function toggleReaction(msg, emoji) {
  react(msg, emoji, !mine(msg).has(emoji));
}
