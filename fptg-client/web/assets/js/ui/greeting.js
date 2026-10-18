import { el, clear } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { stickerNode } from './message.js';

// The greeting in an empty private chat — as in the native client:
//   * an ordinary other side — "nothing here yet" and a random greeting
//     sticker (getGreetingStickers); a click sends it;
//   * a business account — its start page (title, text, sticker);
//   * a bot — what it can do (bot_info.description) and the Start button (/start).
// What to show is decided by the bridge (chat.greeting); the answer is
// cached per chat because the history redraws the empty state on every event.

let hooks = {};
const cache = new Map();     // chatId -> the chat.greeting answer
const pending = new Map();   // chatId -> nodes waiting for the answer

export function mountGreeting(options) {
  hooks = options ?? {};
}

function title(text) {
  return el('div', { class: 'greeting__title' }, text);
}

function note(text) {
  return el('div', { class: 'greeting__text' }, text);
}

/** A sticker button: a click sends it to the open chat. */
function stickerButton(s) {
  return el('button', {
    class: 'greeting__sticker', type: 'button', title: 'Send this sticker',
    onclick: () => {
      hooks.call('greeting.send', { fileId: s.fileId, w: s.w, h: s.h, emoji: s.emoji })
        .catch(hooks.report);
    },
  }, stickerNode({ url: s.url, format: s.format }));
}

function fill(box, g) {
  clear(box);
  if (g?.kind === 'bot') {
    box.append(title('What can this bot do?'),
      note(g.description || g.shortDescription || 'This bot has no description.'),
      el('button', {
        class: 'btn btn--primary greeting__start', type: 'button',
        onclick: () => emit('ui:send', { text: '/start', html: true, silent: false, replyTo: '' }),
      }, 'Start'));
    return;
  }
  if (g?.kind === 'intro') {
    box.append(title(g.title || 'No messages here yet…'));
    if (g.message) box.append(note(g.message));
    if (g.sticker?.url) box.append(stickerButton(g.sticker));
    return;
  }
  box.append(title('No messages here yet…'));
  if (g?.kind === 'greeting' && g.sticker?.url) {
    box.append(note('Send a message or tap the greeting below.'), stickerButton(g.sticker));
  } else {
    box.append(note('Send a message to start the conversation.'));
  }
}

/** The greeting node for an empty chat; the content may arrive later. */
export function greetingNode(chatId) {
  const box = el('div', { class: 'greeting' });
  if (cache.has(chatId)) {
    fill(box, cache.get(chatId));
    return box;
  }
  fill(box, null);
  if (!hooks.call) return box;
  if (!pending.has(chatId)) {
    pending.set(chatId, new Set());
    hooks.call('chat.greeting', { chatId })
      .then((g) => {
        cache.set(chatId, g ?? {});
        for (const node of pending.get(chatId) ?? []) {
          if (node.isConnected) fill(node, g);
        }
      })
      .catch(() => cache.set(chatId, {}))
      .finally(() => pending.delete(chatId));
  }
  pending.get(chatId)?.add(box);
  return box;
}
