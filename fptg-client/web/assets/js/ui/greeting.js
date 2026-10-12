import { el, clear } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { stickerNode } from './message.js';

// Приветствие в пустом личном чате — как у нативного клиента:
//   * обычный собеседник — «пока ничего нет» и случайный приветственный
//     стикер (getGreetingStickers); клик отправляет его;
//   * бизнес-аккаунт — его стартовая страница (заголовок, текст, стикер);
//   * бот — что он умеет (bot_info.description) и кнопка Start (/start).
// Что показать, решает мост (chat.greeting); ответ кэшируется по чату,
// потому что история перерисовывает пустое состояние на каждое событие.

let hooks = {};
const cache = new Map();     // chatId -> ответ chat.greeting
const pending = new Map();   // chatId -> узлы, ждущие ответа

export function mountGreeting(options) {
  hooks = options ?? {};
}

function title(text) {
  return el('div', { class: 'greeting__title' }, text);
}

function note(text) {
  return el('div', { class: 'greeting__text' }, text);
}

/** Стикер-кнопка: клик отправляет его в открытый чат. */
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

/** Узел приветствия для пустого чата; содержимое может доехать позже. */
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
