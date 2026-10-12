import { qs, qsa, el } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, onActiveChat, openThread, chatJoin } from '../core/store.js';
import { mountMentions, closeMentions } from './mentions.js';
import { call } from '../core/net.js';
import { noteTyping, stopAction } from './sendaction.js';

// The message box, and the same formatting toolbar msginput.pas has.
//
// It can be the same toolbar because it is the same mechanism, not a
// lookalike: the buttons wrap the selection in Telegram's own
// MarkdownV2 (or HTML) syntax, and the server hands the whole thing to
// parseTextEntities on the way out. Nothing here knows what an entity
// is - that is the point, and it is why the two windows cannot drift
// in what they produce.
//
// Not WYSIWYG, for the same reason the native one is not: making bold
// text look bold while typing needs a real editor with its own entity
// tree, and this is a plain textarea.

let box = null;
let input = null;
let sendBtn = null;
let joinBtn = null;
// What the box last drew for: inside a thread, or outside one.
let inThread = false;
let lastJoin = 'null';
let emojiBtn = null;
let attachBtn = null;
let htmlBox = null;
let silentBox = null;
let banner = null;
let canSend = false;
// What the next send is: a plain message, an answer to one, or a
// rewrite of one. { mode: 'reply' | 'edit', msg, chatId }.
//
// The chat is noted because a message object does not carry one - it is
// always the open chat's - and a reply left over from another chat
// would be sent to the wrong place.
let pending = null;

// open/close pairs, per syntax. Checked against core.telegram.org's
// Bot API formatting page rather than remembered: MarkdownV2 bold is a
// SINGLE asterisk, which is the easy one to get wrong.
const MARKUP = {
  markdown: {
    bold: ['*', '*'],
    italic: ['_', '_'],
    underline: ['__', '__'],
    strike: ['~', '~'],
    mono: ['`', '`'],
    code: ['```\n', '\n```'],
    spoiler: ['||', '||'],
  },
  html: {
    bold: ['<b>', '</b>'],
    italic: ['<i>', '</i>'],
    underline: ['<u>', '</u>'],
    strike: ['<s>', '</s>'],
    mono: ['<code>', '</code>'],
    code: ['<pre>', '</pre>'],
    spoiler: ['<tg-spoiler>', '</tg-spoiler>'],
  },
};

const isHtml = () => Boolean(htmlBox?.checked);

/** The Silent toggle, for anything sent from outside this module. */
export const isSilent = () => Boolean(silentBox?.checked);

/** Режим разметки (HTML или MarkdownV2) — для подписи к файлам. */
export const htmlMode = () => isHtml();

/**
 * Можно ли сейчас что-то отправить в открытый чат — для отправки
 * файлов (перетаскивание, вставка, скрепка). Тот же ответ, что
 * включает поле ввода.
 */
export const canCompose = () => canSend;

/**
 * Забирает ответ, если он есть: id сообщения, на которое отвечают, или
 * ''. Плашка ответа при этом гаснет — файл и есть этот ответ, как
 * сообщение из поля. Правка (edit) не забирается: к ней файлы не
 * относятся.
 */
export function takeReply() {
  if (pending?.mode !== 'reply') return '';
  const id = String(pending.msg.id);
  pending = null;
  drawBanner();
  return id;
}

/** A line that says which message, in as few words as the message allows. */
function describe(msg) {
  if (msg.text) return msg.text;
  const kind = msg.kind && msg.kind !== 'text' ? msg.kind : 'message';
  return kind.charAt(0).toUpperCase() + kind.slice(1);
}

function drawBanner() {
  if (!banner) return;
  banner.hidden = !pending;
  if (!pending) return;
  qs('.composer__banner-kind', banner).textContent =
    pending.mode === 'edit' ? 'Editing' : 'Reply to';
  qs('.composer__banner-text', banner).textContent = describe(pending.msg);
}

/** Drops whatever the composer was about to answer or rewrite. */
export function cancelPending() {
  if (!pending) return;
  const wasEdit = pending.mode === 'edit';
  pending = null;
  drawBanner();
  // An abandoned edit takes its text with it: leaving the old message
  // sitting in the box would be the next thing sent by accident.
  if (wasEdit) input.value = '';
  input.focus();
}

/** Answers a message. The text box keeps whatever was already typed. */
export function replyTo(msg) {
  if (!canSend) return;
  pending = { mode: 'reply', msg, chatId: store.activeChatId };
  drawBanner();
  input.focus();
}

/**
 * Rewrites a message.
 *
 * The box is filled with the message's PLAIN text, and that is what
 * will be sent: any bold, link or code the original carried is not
 * reconstructed, so saving turns it into what is on screen. That is
 * the honest behaviour for a plain textarea - what is shown is what
 * goes - but it does mean an edit can flatten formatting. Rebuilding
 * MarkdownV2 out of the entities is the fix, and it is a job of its
 * own (see TODO.md).
 */
export function editMessage(msg) {
  if (!canSend) return;
  pending = { mode: 'edit', msg, chatId: store.activeChatId };
  input.value = msg.text ?? '';
  drawBanner();
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

// Сколько своих сообщений (от новых к старым) перебирает стрелка вверх в
// поиске того, которое ещё можно править.
const EDIT_LAST_LOOKBACK = 5;

/**
 * Стрелка вверх в пустом поле — правка последнего своего сообщения, как
 * у Telegram Desktop. Можно ли его править, решает Telegram
 * (message.menu -> canEdit: срок, права), поэтому кандидаты проверяются
 * по очереди, от новых к старым.
 */
async function editLastOwn() {
  const items = store.messages?.items ?? [];
  const own = [];
  for (let i = items.length - 1; i >= 0 && own.length < EDIT_LAST_LOOKBACK; i -= 1) {
    const m = items[i];
    if (m.outgoing && !m.service && m.text) own.push(m);
  }
  for (const m of own) {
    try {
      const info = await call('message.menu', { id: String(m.id) });
      if (info?.canEdit) {
        // Пока шёл вопрос, человек мог начать печатать — не затирать.
        if (!input.value && !pending) editMessage(m);
        return;
      }
    } catch {
      return;
    }
  }
}

function updateEnabled(chat) {
  // Другой чат или ветка — подсказка упоминаний прежнего ни к чему.
  closeMentions();
  // In a comment thread the row to ask is the discussion group's, and
  // there may not be one - see openThread. Commenting on a channel
  // post does not require joining the group, so the thread's own
  // answer wins over the channel row, which always says "no".
  const thread = openThread();
  // Some discussion groups want you in before you may write. That is
  // not "you may not write here" - it is a different answer and it
  // gets different words, see below.
  // Канал или группа, где аккаунт не состоит (пришёл по пересылке):
  // та же кнопка вместо поля ввода — «Join channel» / «Join group».
  const join = thread ? null : chatJoin();
  const joinChat = !!join?.can;
  const mustJoin = !!thread?.mustJoin || joinChat;
  canSend = thread ? (thread.canSend !== false && !mustJoin)
    : (Boolean(chat) && chat.canSend !== false && !joinChat);
  input.disabled = !canSend;
  sendBtn.disabled = !canSend;
  for (const btn of qsa('.composer__format', box)) btn.disabled = !canSend;
  if (emojiBtn) emojiBtn.disabled = !canSend;
  if (attachBtn) attachBtn.disabled = !canSend;

  // A reply belongs to the chat it was written in, and so does an
  // edit. Carrying either into another chat would send it to the wrong
  // place.
  if (pending && (!chat || pending.chatId !== chat.id)) {
    pending = null;
    drawBanner();
  }

  // Telling someone they must join, with no way to do it, is half an
  // answer. The input row gives way to the button that does it.
  box.classList.toggle('composer--join', mustJoin);
  joinBtn.hidden = !mustJoin;
  // Нажатая кнопка гаснет до ответа; новое состояние её возвращает.
  if (!mustJoin) joinBtn.disabled = false;
  if (joinChat) {
    const what = join.channel ? 'channel' : 'group';
    joinBtn.textContent = join.byRequest ? `Apply to join the ${what}` : `Join ${what}`;
  } else {
    joinBtn.textContent = thread?.byRequest
      ? 'Apply to join the group' : 'Join the group';
  }

  if (thread) {
    if (mustJoin) {
      input.placeholder = thread.byRequest
        ? 'Apply to join the group to comment'
        : 'Join the group to comment';
    } else {
      input.placeholder = canSend ? 'Write a comment' : 'You cannot comment here';
    }
  } else if (!chat) input.placeholder = 'Pick a chat to start writing';
  else if (!canSend) input.placeholder = 'You cannot write in this chat';
  else input.placeholder = 'Write a message';
}

// ------------------------------------------------------- formatting
function wrapSelection(open, close) {
  const start = input.selectionStart;
  const end = input.selectionEnd;
  const value = input.value;
  const chosen = value.slice(start, end);

  input.value = value.slice(0, start) + open + chosen + close + value.slice(end);
  if (chosen) {
    // Leave the result selected, so a second button can be applied on
    // top of the first without re-selecting by hand.
    input.setSelectionRange(start, start + open.length + chosen.length + close.length);
  } else {
    // Nothing selected: put the caret between the markers, ready to
    // type the formatted text straight away.
    input.setSelectionRange(start + open.length, start + open.length);
  }
  input.focus();
}

/**
 * Drops text in at the caret, replacing whatever is selected - what the
 * emoji panel needs, and the only way into this box from outside.
 *
 * Note what it does NOT do: escape anything. An emoji carries no
 * MarkdownV2 meaning, and neither does any other character this is used
 * for today. The day something with meaning is inserted here, escaping
 * belongs at that call site, not in this function.
 */
export function insertAtCaret(text) {
  if (!canSend || !text) return;
  const start = input.selectionStart;
  const end = input.selectionEnd;
  input.value = input.value.slice(0, start) + text + input.value.slice(end);
  const caret = start + text.length;
  input.setSelectionRange(caret, caret);
  input.focus();
}

/**
 * Кастомный эмодзи — это сущность, а не символ, поэтому в поле он
 * попадает своей разметкой, как жирный или ссылка: textarea здесь не
 * WYSIWYG. Синтаксис по core.telegram.org/bots/api; внутри — обычный
 * эмодзи, его увидят клиенты, которые кастомный не покажут (без него
 * разметка недействительна). Серверные EscapeMarkdownV2/EscapeHtml
 * пропускают ровно эту форму: id из одних цифр.
 */
export function insertCustomEmoji(id, emoji) {
  const markup = customEmojiMarkup(id, emoji);
  if (markup) insertAtCaret(markup);
}

/** Разметка кастомного эмодзи по текущему режиму, или '' для негодных id. */
export function customEmojiMarkup(id, emoji) {
  if (!/^\d+$/.test(String(id)) || !emoji) return '';
  return isHtml()
    ? `<tg-emoji emoji-id="${id}">${emoji}</tg-emoji>`
    : `![${emoji}](tg://emoji?id=${id})`;
}

function quoteSelection() {
  const start = input.selectionStart;
  const end = input.selectionEnd;
  const value = input.value;
  const chosen = value.slice(start, end) || '';

  let replacement;
  if (isHtml()) {
    replacement = `<blockquote>${chosen}</blockquote>`;
  } else {
    // MarkdownV2 wants a '>' on EVERY line of the quote, not one pair
    // around the block.
    replacement = chosen
      ? chosen.split('\n').map((line) => `>${line}`).join('\n')
      : '>';
  }
  input.value = value.slice(0, start) + replacement + value.slice(end);
  input.setSelectionRange(start, start + replacement.length);
  input.focus();
}

function linkSelection() {
  const start = input.selectionStart;
  const end = input.selectionEnd;
  const value = input.value;
  let text = value.slice(start, end);
  if (!text) {
    text = window.prompt('Link text') ?? '';
    if (!text) return;
  }
  const url = window.prompt('Link target (https://...)') ?? '';
  if (!url) return;

  const replacement = isHtml()
    ? `<a href="${url}">${text}</a>`
    : `[${text}](${url})`;
  input.value = value.slice(0, start) + replacement + value.slice(end);
  input.setSelectionRange(start, start + replacement.length);
  input.focus();
}

/**
 * Best effort, not a parser - the same honest limitation the native
 * "Clear" button carries: a literal asterisk somebody typed as an
 * asterisk is indistinguishable from one that opens bold, and it goes
 * too.
 */
function clearSelection() {
  const start = input.selectionStart;
  const end = input.selectionEnd;
  const value = input.value;
  let chosen = value.slice(start, end);
  if (!chosen) return;

  if (isHtml()) {
    chosen = chosen.replace(/<[^>]+>/g, '');
  } else {
    chosen = chosen
      .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/^>/gm, '')
      .replace(/[*_~`|]/g, '');
  }
  input.value = value.slice(0, start) + chosen + value.slice(end);
  input.setSelectionRange(start, start + chosen.length);
  input.focus();
}

function applyFormat(kind) {
  if (kind === 'quote') return quoteSelection();
  if (kind === 'link') return linkSelection();
  if (kind === 'clear') return clearSelection();
  const pair = MARKUP[isHtml() ? 'html' : 'markdown'][kind];
  if (pair) wrapSelection(pair[0], pair[1]);
  return undefined;
}

// ------------------------------------------------------------- send
function send() {
  if (!canSend) return;
  const text = input.value;
  if (!text.trim()) return;

  if (pending?.mode === 'edit') {
    emit('ui:edit', { id: String(pending.msg.id), text, html: isHtml() });
  } else {
    emit('ui:send', {
      text,
      html: isHtml(),
      silent: Boolean(silentBox?.checked),
      replyTo: pending?.mode === 'reply' ? String(pending.msg.id) : '',
    });
  }
  pending = null;
  drawBanner();
  closeMentions();
  input.value = '';
  stopAction();
  input.focus();
}

export function mountComposer(node) {
  box = node;
  input = qs('.composer__input', box);
  sendBtn = qs('.composer__send', box);
  joinBtn = el('button', {
    class: 'composer__join',
    type: 'button',
    hidden: true,
    onclick: () => {
      joinBtn.disabled = true;
      emit('ui:join-chat');
    },
  });
  qs('.composer__row', box).append(joinBtn);
  emojiBtn = qs('.composer__emoji', box);
  attachBtn = qs('.composer__attach', box);
  // Скрепка: обычный выбор файлов. Картинки по умолчанию уходят сжатыми,
  // как у нативного клиента; переключается в диалоге.
  const picker = qs('#composer-files', box);
  attachBtn?.addEventListener('click', () => picker?.click());
  picker?.addEventListener('change', () => {
    const files = [...picker.files];
    // Сброс — иначе тот же файл, выбранный снова, не даст change.
    picker.value = '';
    if (files.length) emit('ui:attach', { files });
  });
  htmlBox = qs('#composer-html', box);
  silentBox = qs('#composer-silent', box);
  banner = qs('.composer__banner', box);

  // Подсказка «@имя» (ui/mentions.js). До обработчика Enter ниже не
  // важно: она слушает в фазе перехвата.
  mountMentions(input, { enabled: () => canSend, isHtml });
  sendBtn.addEventListener('click', send);
  // «Печатает» собеседнику (ui/sendaction.js). Не при правке своего
  // сообщения — там ничего нового не пишут, официальные клиенты молчат.
  input.addEventListener('input', () => {
    if (!canSend || pending?.mode === 'edit') return;
    noteTyping(!input.value.trim());
  });
  qs('.composer__banner-cancel', banner)?.addEventListener('click', cancelPending);
  // Файлы из буфера обмена (снимок экрана, скопированный в проводнике
  // файл) — в тот же диалог отправки. Текст вставляется как обычно.
  input.addEventListener('paste', (event) => {
    const files = [...(event.clipboardData?.files ?? [])];
    if (!files.length || !canSend) return;
    event.preventDefault();
    emit('ui:attach', { files });
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && pending) {
      event.preventDefault();
      cancelPending();
      return;
    }
    if (event.key === 'ArrowUp' && !input.value && !pending && canSend
        && !event.ctrlKey && !event.shiftKey && !event.altKey && !event.metaKey) {
      event.preventDefault();
      editLastOwn();
      return;
    }
    // Enter sends, Ctrl+Enter inserts a newline - the same split the
    // native input uses, so muscle memory carries between the two.
    if (event.key !== 'Enter' || event.ctrlKey || event.shiftKey) return;
    event.preventDefault();
    send();
  });

  for (const btn of qsa('.composer__format', box)) {
    btn.addEventListener('click', () => applyFormat(btn.dataset.fmt));
  }

  onActiveChat(updateEnabled);
  // Entering or leaving a comment thread is NOT a chat change - the
  // page's active chat stays the channel throughout - but it changes
  // every answer this box gives: whether one may write, what the
  // placeholder says, and whether the join button is there. So it
  // redraws from the message payload too, which is where the thread
  // lives.
  on('store:messages', (state) => {
    // Ветка и «можно вступить» — оба едут со списком сообщений.
    const now = !!state?.thread;
    const joinKey = JSON.stringify(state?.join ?? null);
    if (now === inThread && joinKey === lastJoin) return;
    inThread = now;
    lastJoin = joinKey;
    updateEnabled(store.activeChat);
  });
  updateEnabled(null);
}
