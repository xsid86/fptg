import { el } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { openMenu, closeMenu } from '../util/menu.js';
import { copyText } from '../util/clipboard.js';
import { openEmojiPicker } from './picker.js';

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

/** hooks: { load(cmd,args), act(cmd,args), reply(msg), edit(msg), report(err) } */
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

  const row = el('div', { class: 'menu__reactions' },
    ...info.reactions.map((emoji) => el('button', {
      class: `menu__react${chosen.has(emoji) ? ' is-chosen' : ''}`,
      type: 'button',
      title: chosen.has(emoji) ? 'Remove this reaction' : 'React',
      onclick: () => {
        closeMenu();
        react(msg, emoji, !chosen.has(emoji));
      },
    }, emoji)));

  if (info.allowCustom !== false) {
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

export async function openMessageMenu(anchor, msg, at) {
  let info;
  try {
    info = await hooks.load('message.menu', { id: String(msg.id) });
  } catch (err) {
    hooks.report?.(err);
    return;
  }

  const items = [];
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

  if (info.canDeleteSelf || info.canDeleteAll) {
    if (items.length) items.push('-');
    // Both are offered when both are allowed, and they are different
    // acts: one takes the message off this account's copy of the chat,
    // the other takes it off everybody's. A single "Delete" that
    // quietly picked one would be the wrong kind of convenient.
    if (info.canDeleteAll) {
      items.push({
        label: 'Delete for everyone',
        onSelect: () => hooks.act?.('message.delete',
          { id: String(msg.id), revoke: true }),
      });
    }
    if (info.canDeleteSelf) {
      items.push({
        label: info.canDeleteAll ? 'Delete for me' : 'Delete',
        onSelect: () => hooks.act?.('message.delete',
          { id: String(msg.id), revoke: false }),
      });
    }
  }

  if (!items.length && !info.reactions?.length) return;
  openMenu(anchor, items, { header: reactionStrip(anchor, msg, info), at });
}

/** Clicking a reaction already on the message toggles this account's own. */
export function toggleReaction(msg, emoji) {
  react(msg, emoji, !mine(msg).has(emoji));
}
