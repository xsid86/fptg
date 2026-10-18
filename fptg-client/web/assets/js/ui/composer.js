import { qs, qsa, el } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { store, onActiveChat, openThread, chatJoin } from '../core/store.js';
import { mountMentions, closeMentions } from './mentions.js';
import { call } from '../core/net.js';
import { noteTyping, stopAction } from './sendaction.js';
import { composeRich } from '../util/richcompose.js';
import { toTdEntities, fromMessageEntities } from './editor.js';
import { setCustomEmoji } from '../util/emoji.js';
import { uploadRichFile } from './attach.js';
import { getPref } from '../util/prefs.js';
import { mountSchedule } from './schedule.js';

// The message box and its formatting toolbar.
//
// The box is ui/editor.js: it shows the result, not markup - bold is
// bold, a custom emoji is its picture - and hands over text plus
// entities, which go to TDLib as a formattedText with nothing left to
// parse. The toolbar buttons and the Telegram Desktop shortcuts
// (**bold**, __italic__, ...) both go through it.

let box = null;
let input = null;
let sendBtn = null;
let joinBtn = null;
// What the box last drew for: inside a thread, or outside one.
let inThread = false;
let lastJoin = 'null';
let emojiBtn = null;
let attachBtn = null;
let richBox = null;
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

// A rich message (Rich): blocks by line starts (util/richcompose.js),
// inline formatting and emoji — the field's entities.
const isRich = () => Boolean(richBox?.checked);

// A panel button -> the field's entity kind (ui/editor.js).
const FORMAT_KIND = {
  bold: 'bold', italic: 'italic', underline: 'underline', strike: 'strike',
  mono: 'code', code: 'pre', spoiler: 'spoiler', quote: 'quote', clear: 'clear',
};

/** The Silent toggle, for anything sent from outside this module. */
export const isSilent = () => Boolean(silentBox?.checked);

/** The caption for files (the send window) is written in MarkdownV2. */
export const htmlMode = () => false;

/**
 * Whether anything can be sent to the open chat now — for sending files
 * (dragging, pasting, the paperclip). The same answer that enables the
 * input field.
 */
export const canCompose = () => canSend;

/**
 * Takes the reply if there is one: the id of the message replied to, or
 * ''. The reply plate goes out — the file is that reply, like a message
 * from the field. An edit is not taken: files have nothing to do with it.
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
  if (wasEdit) input.clear();
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
 * Rewrites a message: the box gets its text WITH its formatting (the
 * entities, converted from the byte offsets the page receives).
 */
export function editMessage(msg) {
  if (!canSend) return;
  pending = { mode: 'edit', msg, chatId: store.activeChatId };
  const text = msg.text ?? '';
  input.setFormatted({ text, entities: fromMessageEntities(text, msg.entities) });
  drawBanner();
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

// How many own messages (from newest to oldest) the up arrow goes through
// looking for one that can still be edited.
const EDIT_LAST_LOOKBACK = 5;

/**
 * The up arrow in an empty field — editing the last own message, as in
 * Telegram Desktop. Whether it can be edited is decided by Telegram
 * (message.menu -> canEdit: time limit, rights), so the candidates are
 * checked in turn, from newest to oldest.
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
        // While the question was running, the person may have started typing — do not overwrite.
        if (!input.value && !pending) editMessage(m);
        return;
      }
    } catch {
      return;
    }
  }
}

function updateEnabled(chat) {
  // Another chat or thread — the previous one's mention suggestions are of no use.
  closeMentions();
  // In a comment thread the row to ask is the discussion group's, and
  // there may not be one - see openThread. Commenting on a channel
  // post does not require joining the group, so the thread's own
  // answer wins over the channel row, which always says "no".
  const thread = openThread();
  // Some discussion groups want you in before you may write. That is
  // not "you may not write here" - it is a different answer and it
  // gets different words, see below.
  // A channel or group the account is not a member of (came via a forward):
  // the same button instead of the input field — "Join channel" / "Join group".
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
  // A pressed button goes out until the answer; the new state brings it back.
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
  else if (isRich()) input.placeholder = 'Write a rich message: # heading, - list, | table |, [[Button|https://…]]';
  else input.placeholder = 'Write a message';
}

// ------------------------------------------------------- formatting
/** Text at the caret, instead of the selection (the emoji panel and the like). */
export function insertAtCaret(text) {
  if (!canSend || !text) return;
  input.insertText(text);
  input.focus();
}

/**
 * A custom emoji — a picture in the field, an entity in the message. file —
 * the panel cell ({ format, url }): its address becomes known to the field
 * (util/emoji.js), otherwise it would show the fallback character.
 */
export function insertCustomEmoji(id, emoji, file) {
  if (!canSend || !/^\d+$/.test(String(id)) || !emoji) return;
  if (file?.url) setCustomEmoji({ [String(id)]: { format: file.format, url: file.url } });
  input.insertCustomEmoji(id, emoji);
  input.focus();
}

/**
 * The markup of a custom emoji for the caption in the file send window
 * (a plain field with MarkdownV2 there), or '' for invalid ids.
 */
export function customEmojiMarkup(id, emoji) {
  if (!/^\d+$/.test(String(id)) || !emoji) return '';
  return `![${emoji}](tg://emoji?id=${id})`;
}

/** A link on the selection (the Link button, Ctrl+K); an empty address — remove it. */
function linkSelection() {
  if (input.selectionStart === input.selectionEnd) return;
  const url = window.prompt('Link target (https://...), empty to remove') ?? null;
  if (url === null) return;
  input.toggle('textUrl', { url: url.trim() });
  input.focus();
}

// ------------------------------------------- rich message blocks
/** A prefix to every line of the selection (or the current line). */
function prefixLines(prefix) {
  const value = input.value;
  const a = input.selectionStart;
  const b = input.selectionEnd;
  const start = value.lastIndexOf('\n', a - 1) + 1;
  const starts = [start];
  for (let i = value.indexOf('\n', start); i >= 0 && i < b; i = value.indexOf('\n', i + 1)) starts.push(i + 1);
      // From the end: so the offsets of lines not yet touched stay correct.
  for (const at of starts.reverse()) input.replaceRange(at, at, prefix);
  input.setSelectionRange(a + prefix.length, b + prefix.length * starts.length);
  input.focus();
}

/** A block from a new line: a line break before and after, if there is none. */
function insertBlock(text, selectFrom = 0, selectLen = 0) {
  const value = input.value;
  const start = input.selectionStart;
  const end = input.selectionEnd;
  const before = start > 0 && value[start - 1] !== '\n' ? '\n' : '';
  const after = end < value.length && value[end] !== '\n' ? '\n' : '';
  input.replaceRange(start, end, before + text + after);
  const from = start + before.length + selectFrom;
  input.setSelectionRange(from, from + selectLen);
  input.focus();
}

function richFormat(kind) {
  const chosen = input.value.slice(input.selectionStart, input.selectionEnd);
  switch (kind) {
    case 'heading': return prefixLines('## ');
    case 'list': return prefixLines('- ');
    case 'divider': return insertBlock('---', 3);
    case 'media': {
      // The same file choice as the paperclip, only photos and videos; the
      // answer comes into richAttach (ui/attach.js).
      const picker = qs('#composer-files', box);
      if (!picker) return undefined;
      picker.accept = 'image/*,video/*';
      picker.click();
      return undefined;
    }
    case 'table': {
      const t = '| Column | Column |\n|---|---|\n| Cell | Cell |';
      return insertBlock(t, 2, 6);
    }
    case 'details': {
      const title = 'Title';
      return insertBlock('+++ ' + title + '\n' + (chosen || 'Hidden text') + '\n+++', 4, title.length);
    }
    case 'button': {
      const label = chosen || 'Button';
      const url = 'https://';
      // The caret — right after "https://": the label is there already.
      return insertBlock('[[' + label + '|' + url + ']]', 3 + label.length + url.length, 0);
    }
    default: return undefined;
  }
}

// Rich message files: the line "![](kind:id)" in the text, video info —
// here, by the upload id (composeRich waits for them).
const richMedia = new Map();
let richQueue = Promise.resolve();
let richSeq = 0;

/**
 * Files in Rich mode — as a line at the caret rather than through the send
 * window (called by ui/attach.js). false — not that mode, let the window decide.
 */
export function richAttach(files, mode) {
  if (!isRich() || !canSend || !files.length) return false;
  // All lines at once (consecutive — a collage); the caret goes into the first one's caption.
  const marks = files.map(() => {
    richSeq += 1;
    return `(uploading:${richSeq})`;
  });
  insertBlock(marks.map((mark) => `![]${mark}`).join('\n'), 2, 0);
  files.forEach((file, n) => {
    const mark = marks[n];
    // One at a time (uploadRichFile), in insertion order.
    richQueue = richQueue.then(async () => {
      try {
        const { id, kind, info } = await uploadRichFile(file, mode);
        if (info) richMedia.set(id, info);
        replaceInInput(mark, `(${kind}:${id})`);
      } catch (err) {
        const line = input.value.split('\n').find((l) => l.includes(mark));
        if (line !== undefined) replaceInInput(input.value.includes(`${line}\n`) ? `${line}\n` : line, '');
        emit('ui:error', `${file.name}: ${err.message}`);
      }
    });
  });
  return true;
}

/** Replacing a piece of the field's text without resetting the caret (a file finished uploading). */
function replaceInInput(from, to) {
  const at = input.value.indexOf(from);
  if (at < 0) return;
  input.replaceRange(at, at + from.length, to, [], { keepCaret: true });
}

function applyFormat(kind) {
  if (kind === 'link') return linkSelection();
  if (isRich() && ['heading', 'list', 'divider', 'table', 'details', 'button', 'media'].includes(kind)) {
    return richFormat(kind);
  }
  if (FORMAT_KIND[kind]) {
    input.toggle(FORMAT_KIND[kind]);
    input.focus();
  }
  return undefined;
}

// ------------------------------------------------------------- send
/**
 * schedule — scheduled sending (ui/schedule.js): a unix date or -1 ("when
 * online"); 0 — at once. Editing an own message — always at once.
 */
function send(schedule = 0) {
  if (!canSend) return;
  const doc = input.getFormatted();
  if (!doc.text.trim()) return;
  const later = schedule && pending?.mode !== 'edit' ? { schedule } : {};

  if (pending?.mode === 'edit') {
    emit('ui:edit', { id: String(pending.msg.id), text: doc.text, entities: toTdEntities(doc.entities) });
  } else if (isRich()) {
    let blocks;
    try {
      blocks = composeRich(doc, (id) => richMedia.get(id) ?? null);
    } catch (err) {
      emit('ui:error', err.message);
      return;
    }
    if (!blocks.length) return;
    emit('ui:send-rich', {
      blocks,
      silent: Boolean(silentBox?.checked),
      replyTo: pending?.mode === 'reply' ? String(pending.msg.id) : '',
      ...later,
    });
  } else {
    emit('ui:send', {
      text: doc.text,
      entities: toTdEntities(doc.entities),
      silent: Boolean(silentBox?.checked),
      replyTo: pending?.mode === 'reply' ? String(pending.msg.id) : '',
      ...later,
    });
  }
  if (later.schedule) emit('ui:scheduled', later.schedule);
  pending = null;
  drawBanner();
  closeMentions();
  input.clear();
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
  // The paperclip: an ordinary file choice. Pictures go compressed by
  // default, as in the native client; this is switched in the dialog.
  const picker = qs('#composer-files', box);
  // A filter may have stayed from the Media button (only photos and videos).
  attachBtn?.addEventListener('click', () => {
    if (!picker) return;
    picker.accept = '';
    picker.click();
  });
  picker?.addEventListener('change', () => {
    const files = [...picker.files];
    // Reset — otherwise the same file chosen again would not fire change.
    picker.value = '';
    if (files.length) emit('ui:attach', { files });
  });
  richBox = qs('#composer-rich', box);
  silentBox = qs('#composer-silent', box);
  // Rich: its own row of panel buttons (blocks/_composer.scss).
  richBox?.addEventListener('change', () => {
    box.classList.toggle('composer--rich', isRich());
    updateEnabled(store.activeChat);
    input.focus();
  });
  banner = qs('.composer__banner', box);

  // The "@name" suggestion (ui/mentions.js). Before the Enter handler below
  // does not matter: it listens in the capture phase.
  mountMentions(input, { enabled: () => canSend });
  // Ctrl+K in the field — the same link as the Link button.
  input.addEventListener('editor:link', linkSelection);
  sendBtn.addEventListener('click', () => send());
  // Scheduled sending — the button to the left of voice recording.
  mountSchedule(qs('.composer__row', box), {
    canSend: () => canSend,
    hasText: () => !!input.getFormatted().text.trim(),
    send: (schedule) => send(schedule),
    report: (error) => emit('ui:error', error?.message ?? String(error)),
  });
  // "Typing" to the other side (ui/sendaction.js). Not while editing an own
  // message — nothing new is written there, the official clients stay silent.
  input.addEventListener('input', () => {
    if (!canSend || pending?.mode === 'edit') return;
    noteTyping(!input.value.trim());
  });
  qs('.composer__banner-cancel', banner)?.addEventListener('click', cancelPending);
  // Files from the clipboard (a screenshot, a file copied in Explorer) — into
  // the same send dialog. Text is pasted as usual.
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
    // "Send messages with: Ctrl+Enter" (Chat settings) — the other way round:
    // Enter is a new line (the field inserts it, ui/editor.js).
    if (event.key !== 'Enter' || event.shiftKey) return;
    if (getPref('sendByCtrlEnter') ? !(event.ctrlKey || event.metaKey) : event.ctrlKey) return;
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
    // The thread and "can join" — both come with the message list.
    const now = !!state?.thread;
    const joinKey = JSON.stringify(state?.join ?? null);
    if (now === inThread && joinKey === lastJoin) return;
    inThread = now;
    lastJoin = joinKey;
    updateEnabled(store.activeChat);
  });
  updateEnabled(null);
}
