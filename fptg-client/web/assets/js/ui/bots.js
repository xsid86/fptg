import { el, clear, qs, append } from '../core/dom.js';
import { on, emit } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { openMenu } from '../util/menu.js';
import { copyText } from '../util/clipboard.js';
import { openLink } from './links.js';
import { openMiniApp } from './shell.js';
import { store } from '../core/store.js';
import { fillAvatar } from '../util/avatar.js';
import { customEmojiNode } from '../util/emoji.js';

// Working with bots: buttons under messages, the keyboard above the input
// field, commands, mini apps (Mini Apps).
//
// A mini app opens NOT here but in a separate window (miniapp.pas): popular
// apps forbid being shown in a frame of someone else's site. The page only
// asks webapp.open and passes its theme colours.
//
// What the buttons are and how to press them — per td_api.tl (TDLib
// 1.8.67); the bridge — bot.callback / bot.info / bot.userChat in
// webapi.pas, the buttons come already parsed (KeyboardRowsJson): text,
// kind and what the view needs.

let hooks = {};
let composer = null;
let kbBox = null;          // the keyboard above the input field
let kbToggle = null;       // show / hide it
let menuBtn = null;        // the bot's commands
let keyboard = null;       // the chat's latest keyboard ({msgId, rows, oneTime})
const hiddenKb = new Set();   // msgId of keyboards that were hidden (or one-time ones after a press)
let botInfo = null;        // {commands, menuButton} of the open bot
let infoFor = null;        // which chat botInfo is for
let input = null;          // the composer's input field
let inlineBox = null;      // inline query results above the input field
let inlineTimer = 0;
let inlineAsked = 0;       // the request number: an answer to stale text is discarded
let pendingInline = null;  // {chatId, text}: put in after going to the chat
let ownPlaceholder = null; // the field's placeholder before the bot set its own
const forcedReply = new Set();  // msgId that force_reply has already turned a reply on for

// Messages to the person — as a notice at the top of the window
// (ui/notices.js), not in the status bar.
const notify = (text) => hooks.notice(text);

// The page's theme colours under themeParameters names (td_api.tl) — the
// mini app gets them. From the CSS variables that paint the page.
const THEME_VARS = {
  background_color: '--c-surface',
  secondary_background_color: '--c-bg',
  header_background_color: '--c-surface',
  bottom_bar_background_color: '--c-surface',
  section_background_color: '--c-surface',
  section_separator_color: '--c-border',
  text_color: '--c-text',
  accent_text_color: '--c-accent',
  section_header_text_color: '--c-text-dim',
  subtitle_text_color: '--c-text-dim',
  destructive_text_color: '--c-danger',
  hint_color: '--c-text-faint',
  link_color: '--c-accent',
  button_color: '--c-accent',
  button_text_color: '--c-accent-text',
};

function pageTheme() {
  const css = getComputedStyle(document.documentElement);
  const theme = {};
  for (const [name, prop] of Object.entries(THEME_VARS)) {
    const value = css.getPropertyValue(prop).trim();
    if (/^#[0-9a-f]{6}$/i.test(value)) theme[name] = value;
  }
  return theme;
}

/** source: inline (msg — the message with the button), menu, keyboard (buttonText). */
async function openApp(source, url, msg, buttonText = '') {
  try {
    // The server returns the address and everything for the window; the
    // shell (or a browser tab) opens the window — ui/shell.js.
    openMiniApp(await hooks.call('webapp.open', {
      source,
      url,
      msgId: msg ? String(msg.id) : '',
      buttonText,
      title: (source === 'inline' && msg?.senderName) || store.activeChat?.title || 'Mini App',
      theme: pageTheme(),
    }));
  } catch (error) {
    hooks.report(error);
  }
}

/** An attachment menu bot (ui/attachmenu.js) — a Mini App in the open chat. */
export async function openAttachBot(botId, name) {
  try {
    openMiniApp(await hooks.call('webapp.open', {
      source: 'attach', botId: String(botId), url: '', title: name || 'Mini App', theme: pageTheme(),
    }));
  } catch (error) {
    hooks.report(error);
  }
}

/** A bot answer with show_alert — a window with OK, as in the native client. */
function showAlert(text) {
  const dialog = el('dialog', { class: 'confirm', 'aria-label': 'Bot' });
  const ok = el('button', {
    class: 'btn confirm__button', type: 'button', onclick: () => dialog.close(),
  }, 'OK');
  dialog.append(
    el('p', { class: 'confirm__note confirm__note--plain' }, text),
    el('div', { class: 'confirm__buttons' }, ok));
  dialog.addEventListener('close', () => dialog.remove());
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) dialog.close();
  });
  document.body.append(dialog);
  dialog.showModal();
  ok.focus();
}

/**
 * A choice window for request buttons: own chats of the needed kind, search,
 * checkboxes (up to max) or a single choice. Resolves to the chosen chats or null.
 */
export function pickChats({ title, candidates, max }) {
  return new Promise((resolve) => {
    const many = max > 1;
    const chosen = new Set();
    const dialog = el('dialog', { class: 'confirm share', 'aria-label': title });
    const send = el('button', { class: 'btn confirm__button', type: 'button', disabled: true }, 'Send');
    const list = el('ul', { class: 'share__list' });
    const search = el('input', {
      class: 'field__input', type: 'search', placeholder: 'Search', autocomplete: 'off',
    });
    let answer = null;

    const sync = () => {
      send.disabled = chosen.size === 0;
      // The limit is reached — the remaining checkboxes are disabled.
      for (const box of list.querySelectorAll('input[type="checkbox"]')) {
        box.disabled = !box.checked && chosen.size >= max;
      }
    };

    const row = (chat) => {
      const avatar = el('span', { class: `avatar avatar--sm share__avatar accent-${chat.color || 'f0'}` });
      fillAvatar(avatar, chat);
      const box = el('input', { type: many ? 'checkbox' : 'radio', name: 'share-pick' });
      box.addEventListener('change', () => {
        if (!many) chosen.clear();
        if (box.checked) chosen.add(chat.id);
        else chosen.delete(chat.id);
        sync();
      });
      return el('li', { class: 'share__item', dataset: { name: (chat.title || '').toLowerCase() } },
        el('label', { class: 'share__label' }, box, avatar, el('span', { class: 'share__name' }, chat.title || '')));
    };
    list.append(...candidates.map(row));
    search.addEventListener('input', () => {
      const q = search.value.trim().toLowerCase();
      for (const li of list.children) li.hidden = !!q && !li.dataset.name.includes(q);
    });

    send.addEventListener('click', () => {
      answer = candidates.filter((c) => chosen.has(c.id));
      dialog.close();
    });
    append(dialog, [
      el('p', { class: 'confirm__text' }, title),
      many ? el('p', { class: 'confirm__note' }, `Up to ${max}`) : null,
      el('label', { class: 'field share__search' }, search),
      list,
      el('div', { class: 'confirm__buttons' },
        el('button', { class: 'btn confirm__button', type: 'button', onclick: () => dialog.close() }, 'Cancel'),
        send)]);
    dialog.addEventListener('click', (event) => {
      if (event.target === dialog) dialog.close();
    });
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(answer);
    });
    document.body.append(dialog);
    dialog.showModal();
    search.focus();
  });
}

/** Yes / no — the same confirmation window. */
function ask(text, yes) {
  return new Promise((resolve) => {
    const dialog = el('dialog', { class: 'confirm' });
    let answer = false;
    const ok = el('button', {
      class: 'btn confirm__button', type: 'button',
      onclick: () => { answer = true; dialog.close(); },
    }, yes);
    dialog.append(el('p', { class: 'confirm__note confirm__note--plain' }, text),
      el('div', { class: 'confirm__buttons' },
        el('button', { class: 'btn confirm__button', type: 'button', onclick: () => dialog.close() }, 'Cancel'),
        ok));
    dialog.addEventListener('close', () => { dialog.remove(); resolve(answer); });
    document.body.append(dialog);
    dialog.showModal();
    ok.focus();
  });
}

async function shareUsers(msgId, button) {
  // Bots: false — not allowed, true — bots only, no field — either.
  const kinds = button.bots === true ? ['bot']
    : button.bots === false ? ['private'] : ['private', 'bot'];
  const picked = await pickChats({
    title: button.text.trim(),
    candidates: store.chats.filter((c) => kinds.includes(c.kind)),
    max: Math.max(1, button.max || 1),
  });
  if (!picked?.length) return;
  try {
    // A private chat's id is the same as the user's id.
    await hooks.call('bot.shareUsers', {
      msgId: String(msgId), buttonId: button.buttonId, userIds: picked.map((c) => String(c.id)),
    });
  } catch (error) {
    hooks.report(error);
  }
}

async function shareChat(msgId, button) {
  const picked = await pickChats({
    title: button.text.trim(),
    candidates: store.chats.filter((c) => c.kind === (button.channel ? 'channel' : 'group')),
    max: 1,
  });
  if (!picked?.length) return;
  try {
    await hooks.call('bot.shareChat', {
      msgId: String(msgId), buttonId: button.buttonId, chatId: String(picked[0].id),
    });
  } catch (error) {
    hooks.report(error);
  }
}

// ------------------------------------------------------- inline mode
// "@bot query" in the input field — the bot answers with a list of results
// (getInlineQueryResults), a click sends the chosen one to the chat
// (sendInlineQueryResultMessage). As in the native client: the query goes
// out only when there is a space after the name, and after a typing pause.
const INLINE_RE = /^@([A-Za-z0-9_]{3,32}) ([\s\S]*)$/;  // @gif, @vid, @pic — three letters
const INLINE_DELAY_MS = 350;

function hideInline() {
  inlineAsked += 1;
  clearTimeout(inlineTimer);
  inlineBox.hidden = true;
  clear(inlineBox);
}

function setComposerText(text) {
  input.value = text;
  input.focus();
  input.setSelectionRange(text.length, text.length);
  // As if typed by hand: both the inline mode and the field height see it.
  input.dispatchEvent(new Event('input', { bubbles: true }));
}

async function askInline(username, query) {
  const my = ++inlineAsked;
  let data;
  try {
    data = await hooks.call('inline.query', { username, query });
  } catch {
    if (my === inlineAsked) hideInline();
    return;
  }
  if (my !== inlineAsked) return;
  const results = data?.results ?? [];
  if (!results.length) {
    hideInline();
    return;
  }
  clear(inlineBox).append(...results.map((r) => el('button', {
    class: 'composer__inline-item',
    type: 'button',
    onclick: async () => {
      try {
        await hooks.call('inline.send', { queryId: data.queryId, resultId: r.id, silent: hooks.silent() });
        setComposerText('');
      } catch (error) {
        hooks.report(error);
      }
      hideInline();
    },
  },
  el('span', { class: 'composer__inline-title' }, r.title || r.kind),
  r.description ? el('span', { class: 'composer__inline-desc' }, r.description) : null)));
  inlineBox.hidden = false;
}

function onComposerInput() {
  const m = INLINE_RE.exec(input.value);
  clearTimeout(inlineTimer);
  if (!m) {
    if (!inlineBox.hidden) hideInline();
    return;
  }
  inlineTimer = setTimeout(() => askInline(m[1], m[2]).catch(console.error), INLINE_DELAY_MS);
}

/**
 * The switchInline button: "@bot query" — into this chat or a chosen one
 * (the chat kinds the bot allowed).
 */
async function switchInline(msg, button) {
  if (!msg?.botUsername) {
    notify('This button is not supported yet');
    return;
  }
  const text = `@${msg.botUsername} ${button.query || ''}`;
  if (button.target === 'current') {
    setComposerText(text);
    return;
  }
  const kinds = [];
  if (button.users) kinds.push('private');
  if (button.bots) kinds.push('bot');
  if (button.groups) kinds.push('group');
  if (button.channels) kinds.push('channel');
  const picked = await pickChats({
    title: 'Choose a chat',
    candidates: store.chats.filter((c) => kinds.includes(c.kind)),
    max: 1,
  });
  if (!picked?.length) return;
  if (picked[0].id === store.activeChatId) {
    setComposerText(text);
    return;
  }
  pendingInline = { chatId: picked[0].id, text };
  hooks.openChat(picked[0].id);
}

async function sharePhone() {
  const bot = store.activeChat?.title || 'this bot';
  if (!(await ask(`Share your phone number with ${bot}?`, 'Share'))) return;
  try {
    await hooks.call('bot.sharePhone', {});
  } catch (error) {
    hooks.report(error);
  }
}

/**
 * A window with fields: text — the question, body — the form nodes, ok — the
 * button label. check() — the check before closing (return the error text or
 * ''). The promise resolves to true if ok was pressed.
 */
export function formDialog({ text, body = [], ok, check = () => '' }) {
  return new Promise((resolve) => {
    const dialog = el('dialog', { class: 'confirm' });
    const error = el('p', { class: 'confirm__note bots__form-error', role: 'alert' });
    let answer = false;
    const okBtn = el('button', {
      class: 'btn confirm__button', type: 'button',
      onclick: () => {
        const problem = check();
        error.textContent = problem;
        if (problem) return;
        answer = true;
        dialog.close();
      },
    }, ok);
    dialog.append(
      el('p', { class: 'confirm__note confirm__note--plain' }, text),
      el('div', { class: 'bots__form' }, ...body),
      error,
      el('div', { class: 'confirm__buttons' },
        el('button', { class: 'btn confirm__button', type: 'button', onclick: () => dialog.close() }, 'Cancel'),
        okBtn));
    dialog.addEventListener('close', () => { dialog.remove(); resolve(answer); });
    document.body.append(dialog);
    dialog.showModal();
    (dialog.querySelector('input') ?? okBtn).focus();
  });
}

export const field = (attrs) => el('input', { class: 'field__input bots__input', autocomplete: 'off', ...attrs });

export function checkRow(label, checked, disabled = false) {
  const box = el('input', { type: 'checkbox', checked, disabled });
  return { box, node: el('label', { class: 'confirm__check' }, box, el('span', {}, label)) };
}

/** A bot's callback answer: the text as a notice or a window, a link. */
function handleAnswer(answer) {
  if (answer?.text) {
    if (answer.alert) showAlert(answer.text);
    else notify(answer.text);
  }
  if (answer?.url) openLink(answer.url);
}

/** Signing in to a site via Telegram (loginUrl): as in the native client. */
async function loginUrl(msg, button) {
  let info;
  try {
    info = await hooks.call('bot.loginUrl', { msgId: String(msg.id), buttonId: button.buttonId });
  } catch {
    openLink(button.url);
    return;
  }
  if (!info.confirm) {
    openLink(info.url || button.url);
    return;
  }
  const write = checkRow('Allow the bot to send me messages', true);
  const yes = await formDialog({
    text: `Log in to ${info.domain} with your Telegram account?`,
    body: info.writeAccess ? [write.node] : [],
    ok: 'Log in',
  });
  if (!yes) return;
  try {
    const r = await hooks.call('bot.loginUrlConfirm', {
      msgId: String(msg.id), buttonId: button.buttonId,
      allowWrite: info.writeAccess && write.box.checked,
    });
    openLink(r.url || info.url);
  } catch (error) {
    hooks.report(error);
  }
}

/** A callback with the 2FA password: the person enters it, it goes to TDLib. */
async function callbackWithPassword(msg, button) {
  const pass = field({ type: 'password', autocomplete: 'current-password', placeholder: 'Password' });
  const yes = await formDialog({
    text: 'Enter your two-step verification password to confirm this action.',
    body: [pass],
    ok: 'Confirm',
    check: () => (pass.value ? '' : 'Enter the password'),
  });
  if (!yes) return;
  try {
    handleAnswer(await hooks.call('bot.callback', {
      id: String(msg.id), data: button.data, password: pass.value,
    }));
  } catch (error) {
    hooks.report(error);
  }
}

/** The "buy" button — paying the message's invoice (ui/payments.js). */
function buy(msg) {
  emit('ui:pay-invoice', { msgId: String(msg.id) });
}

/** Why there is no location — by the GeolocationPositionError code. */
export function geoErrorText(error) {
  switch (error?.code) {
    case 1:
      return 'Location access is denied. Allow it for desktop apps in Windows '
        + 'Settings → Privacy & security → Location.';
    case 2:
      return 'Location is unavailable. Check that Location is turned on in '
        + 'Windows Settings → Privacy & security.';
    case 3:
      return 'Finding the location took too long. Try again.';
    default:
      return 'Location is not available';
  }
}

/** Location: the browser asks for permission, the person for consent to send it. */
async function requestLocation() {
  if (!navigator.geolocation) {
    notify('Location is not available');
    return;
  }
  let pos;
  try {
    pos = await new Promise((resolve, reject) => navigator.geolocation.getCurrentPosition(
      resolve, reject, { enableHighAccuracy: true, timeout: 15000 }));
  } catch (error) {
    notify(geoErrorText(error));
    return;
  }
  const bot = store.activeChat?.title || 'this bot';
  if (!(await ask(`Send your location to ${bot}?`, 'Send'))) return;
  try {
    await hooks.call('bot.sendLocation', {
      lat: pos.coords.latitude, lon: pos.coords.longitude, accuracy: pos.coords.accuracy || 0,
    });
  } catch (error) {
    hooks.report(error);
  }
}

const POLL_OPTIONS_MAX = 10;

/**
 * A poll: the question, options, anonymity, quiz. button — the bot button's
 * restrictions (forceRegular / forceQuiz), cmd — where to send: the bot
 * button or the paperclip menu (ui/attachmenu.js).
 */
export async function openPollDialog(button, cmd = 'bot.sendPoll') {
  const question = field({ type: 'text', placeholder: 'Question', maxLength: 300 });
  const list = el('div', { class: 'bots__options' });
  const addOption = () => {
    if (list.children.length >= POLL_OPTIONS_MAX) return;
    list.append(field({ type: 'text', placeholder: `Option ${list.children.length + 1}`, maxLength: 100 }));
    more.disabled = list.children.length >= POLL_OPTIONS_MAX;
  };
  const more = el('button', { class: 'btn bots__add', type: 'button', onclick: addOption }, 'Add an option');
  addOption();
  addOption();
  const anonymous = checkRow('Anonymous voting', true);
  const multiple = checkRow('Multiple answers', false, !!button.forceQuiz);
  const quiz = checkRow('Quiz mode', !!button.forceQuiz, !!button.forceQuiz || !!button.forceRegular);
  const correct = field({ type: 'number', min: '1', value: '1', placeholder: 'Correct option' });
  const correctRow = el('label', { class: 'bots__inline', hidden: !quiz.box.checked },
    el('span', {}, 'Correct option'), correct);
  quiz.box.addEventListener('change', () => {
    correctRow.hidden = !quiz.box.checked;
    if (quiz.box.checked) multiple.box.checked = false;
    multiple.box.disabled = quiz.box.checked;
  });
  const options = () => [...list.children].map((n) => n.value.trim()).filter(Boolean);
  const yes = await formDialog({
    text: 'Create a poll',
    body: [question, list, more, anonymous.node, multiple.node, quiz.node, correctRow],
    ok: 'Send',
    check: () => {
      if (!question.value.trim()) return 'Enter a question';
      if (options().length < 2) return 'Add at least two options';
      const n = Number(correct.value);
      if (quiz.box.checked && !(n >= 1 && n <= options().length)) return 'Pick the correct option';
      return '';
    },
  });
  if (!yes) return;
  try {
    await hooks.call(cmd, {
      question: question.value.trim(),
      options: options(),
      anonymous: anonymous.box.checked,
      multiple: multiple.box.checked,
      quiz: quiz.box.checked,
      correct: Math.max(0, Number(correct.value) - 1),
    });
  } catch (error) {
    hooks.report(error);
  }
}

/** Create a managed bot: the name and username suggested by the bot. */
async function requestManagedBot(button) {
  const name = field({ type: 'text', placeholder: 'Bot name', value: button.name || '', maxLength: 64 });
  const username = field({ type: 'text', placeholder: 'Bot username', value: button.username || '', maxLength: 32 });
  const yes = await formDialog({
    text: `${store.activeChat?.title || 'This bot'} offers to create a bot for you.`,
    body: [name, username],
    ok: 'Create',
    check: () => (name.value.trim() && username.value.trim() ? '' : 'Fill in both fields'),
  });
  if (!yes) return;
  try {
    await hooks.call('bot.createBot', { name: name.value, username: username.value });
    notify('Bot created');
  } catch (error) {
    hooks.report(error);
  }
}

/** A button press — inline (under a message) or a keyboard one (msg = null). */
async function press(msg, button) {
  switch (button.kind) {
    case 'callback': {
      let answer;
      try {
        answer = await hooks.call('bot.callback', { id: String(msg.id), data: button.data });
      } catch (error) {
        // Silently — the button looked dead. A live log: TDLib answers with
        // error 502 "The bot is not responding" when the bot did not answer
        // the press within ~15 s; that is what we say.
        // The page's command timeout (15 s) fires a fraction of a second
        // before TDLib's answer (~15.2 s per the log) — the same case.
        const text = error instanceof Error ? error.message : String(error);
        notify(/timed out|not responding/i.test(text) ? 'The bot is not responding' : text);
        return;
      }
      handleAnswer(answer);
      return;
    }
    case 'callbackPassword':
      await callbackWithPassword(msg, button);
      return;
    case 'game':
      // A game is a callback too (payload Game); the bot answers with a link to it.
      try {
        handleAnswer(await hooks.call('bot.callback', { id: String(msg.id), game: true }));
      } catch (error) {
        hooks.report(error);
      }
      return;
    case 'login':
      await loginUrl(msg, button);
      return;
    case 'buy':
      await buy(msg);
      return;
    case 'disabled':
      return;
    case 'requestLocation':
      await requestLocation();
      return;
    case 'requestPoll':
      await openPollDialog(button);
      return;
    case 'requestManagedBot':
      await requestManagedBot(button);
      return;
    case 'url':
      openLink(button.url);
      return;
    case 'copy':
      await copyText(button.copy);
      notify('Copied to clipboard');
      return;
    case 'user':
      try {
        const chat = await hooks.call('bot.userChat', { userId: button.userId });
        if (chat?.chatId) hooks.openChat(chat.chatId);
      } catch (error) {
        hooks.report(error);
      }
      return;
    case 'text':
      hooks.send(button.text);
      return;
    case 'webapp':
      // Under a message — inline; on the keyboard above the input field (no
      // msg) — keyboard: such an app's data goes to the bot on behalf of the button.
      if (msg) await openApp('inline', button.url, msg);
      else await openApp('keyboard', button.url, null, button.text);
      return;
    // Request buttons — only on the keyboard above the input field; their
    // source is the message with that keyboard.
    case 'requestUsers':
      if (keyboard) await shareUsers(keyboard.msgId, button);
      return;
    case 'requestChat':
      if (keyboard) await shareChat(keyboard.msgId, button);
      return;
    case 'requestPhone':
      await sharePhone();
      return;
    case 'switchInline':
      await switchInline(msg, button);
      return;
    default:
      notify('This button is not supported yet');
  }
}

function buttonNode(msg, button, cls) {
  // The colour the bot set (buttonStyle*): is-style-danger and so on.
  const style = button.style ? ` is-style-${button.style}` : '';
  return el('button', {
    class: `${cls} is-${button.kind}${style}`,
    type: 'button',
    title: button.kind === 'url' || button.kind === 'login' ? button.url : '',
    // inlineKeyboardButtonTypeDisabled — visible but not pressable.
    disabled: button.kind === 'disabled',
    onclick: (event) => {
      event.stopPropagation();
      press(msg, button).catch(console.error);
    },
  },
  // icon_custom_emoji_id — before the text; while there is no file, just without it.
  button.emoji ? customEmojiNode(button.emoji, `${cls}-emoji`) : null,
  el('span', { class: `${cls}-text` }, button.text),
  button.kind === 'url' || button.kind === 'webapp'
    ? icon(button.kind === 'url' ? 'link' : 'dots', `${cls}-mark icon--sm`) : null);
}

/** One button — for rich message blocks (ui/richmessage.js):
 *  the same look and the same press as under a message. */
export function inlineButtonNode(msg, button, cls) {
  return buttonNode(msg, button, cls);
}

/** Inline buttons under a message — called by message.js. */
export function renderInlineKeyboard(msg) {
  return el('div', { class: 'message__keyboard' },
    ...msg.keyboard.map((row) => el('div', { class: 'message__kb-row' },
      ...row.map((b) => buttonNode(msg, b, 'message__kb-btn')))));
}

// ----------------------------------------------- keyboard above the field
function drawKeyboard() {
  const shown = !!keyboard && !hiddenKb.has(keyboard.msgId);
  kbToggle.hidden = !keyboard;
  kbToggle.classList.toggle('is-active', shown);
  kbBox.hidden = !shown;
  if (!shown) {
    clear(kbBox);
    return;
  }
  clear(kbBox).append(...keyboard.rows.map((row) => el('div', { class: 'composer__kb-row' },
    ...row.map((b) => {
      const node = buttonNode(null, b, 'composer__kb-btn');
      if (keyboard.oneTime) {
        // A one-time keyboard hides after a press.
        node.addEventListener('click', () => {
          hiddenKb.add(keyboard.msgId);
          drawKeyboard();
        });
      }
      return node;
    }))));
}

function setKeyboard(next) {
  applyPlaceholder(next?.placeholder || '');
  // force_reply: the input field replies to the message with the markup at
  // once — once per message, after that the person is free to cancel the reply.
  if (next?.forceReply && next.msgId && !forcedReply.has(next.msgId)) {
    const target = store.messages?.items?.find((m) => m.id === next.msgId);
    if (target) {
      forcedReply.add(next.msgId);
      hooks.replyTo?.(target);
    }
  }
  const same = keyboard && next && keyboard.msgId === next.msgId
    && JSON.stringify(keyboard.rows) === JSON.stringify(next.rows);
  if (same) return;
  keyboard = next?.rows?.length ? next : null;
  drawKeyboard();
}

/**
 * The keyboard anew — when a custom emoji file arrived: the markup does not
 * change, and setKeyboard considers it the same (main.js).
 */
export function redrawBotKeyboard() {
  if (kbBox) drawKeyboard();
}

/** The input field placeholder from the bot (input_field_placeholder); '' — restore our own. */
function applyPlaceholder(text) {
  if (!input) return;
  if (text) {
    if (ownPlaceholder === null) ownPlaceholder = input.placeholder;
    input.placeholder = text;
  } else if (ownPlaceholder !== null) {
    input.placeholder = ownPlaceholder;
    ownPlaceholder = null;
  }
}

// --------------------------------------------------------- commands
// The bot's menu button: if the bot set a mini app (botMenuButton) — it has
// its text and opens the app, as in the native client; otherwise — Menu
// with the command list.
function drawMenu() {
  const app = botInfo?.menuButton?.url;
  menuBtn.hidden = !app && !(botInfo?.commands?.length > 0);
  menuBtn.textContent = app ? (botInfo.menuButton.text || 'Open') : 'Menu';
  menuBtn.title = app ? 'Open the bot app' : 'Bot commands';
}

function openCommands() {
  if (botInfo?.menuButton?.url) {
    openApp('menu', botInfo.menuButton.url, null).catch(console.error);
    return;
  }
  if (!botInfo?.commands?.length) return;
  openMenu(menuBtn, botInfo.commands.map((c) => ({
    label: `/${c.command}${c.description ? ` — ${c.description}` : ''}`,
    onSelect: () => hooks.send(`/${c.command}`),
  })));
}

async function loadBotInfo(chat) {
  botInfo = null;
  infoFor = chat?.id ?? null;
  drawMenu();
  if (chat?.kind !== 'bot') return;
  try {
    const info = await hooks.call('bot.info', { chatId: chat.id });
    if (infoFor !== chat.id) return;
    botInfo = info;
  } catch {
    botInfo = null;
  }
  drawMenu();
}

/**
 * hooks: { call(cmd, args), report(err), notice(text), openChat(id), send(text), silent() }
 * composerNode — #composer: the keyboard goes above the input field, the
 * buttons (Menu and the keyboard toggle) — at the start of the right group.
 */
export function mountBots(composerNode, options) {
  hooks = options ?? {};
  composer = composerNode;

  kbBox = el('div', { class: 'composer__keyboard', hidden: true });
  inlineBox = el('div', { class: 'composer__inline', hidden: true });
  qs('.composer__row', composer).before(inlineBox, kbBox);
  input = qs('.composer__input', composer);
  input.addEventListener('input', onComposerInput);
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !inlineBox.hidden) hideInline();
  });

  const actions = qs('.composer__group--actions', composer);
  menuBtn = el('button', {
    class: 'btn composer__menu', type: 'button', hidden: true, title: 'Bot commands',
    onclick: openCommands,
  }, 'Menu');
  kbToggle = el('button', {
    class: 'btn btn--icon composer__kb-toggle', type: 'button', hidden: true,
    title: 'Bot keyboard',
    onclick: () => {
      if (!keyboard) return;
      if (hiddenKb.has(keyboard.msgId)) hiddenKb.delete(keyboard.msgId);
      else hiddenKb.add(keyboard.msgId);
      drawKeyboard();
    },
  }, icon('keyboard'), el('span', { class: 'u-sr-only' }, 'Bot keyboard'));
  actions.prepend(menuBtn, kbToggle);

  on('store:messages', (payload) => setKeyboard(payload?.replyKeyboard ?? null));
  on('store:active', (chat) => {
    setKeyboard(null);
    hideInline();
    loadBotInfo(chat).catch(console.error);
    // Going by a switchInline button: the text goes into the new chat's field.
    if (pendingInline && chat?.id === pendingInline.chatId) {
      const { text } = pendingInline;
      pendingInline = null;
      setTimeout(() => setComposerText(text), 0);
    }
  });
  // A chat row is sometimes refined later (a chat not from the list) — its
  // kind becomes known only then.
  on('store:active-row', (chat) => {
    if (chat?.id !== infoFor) loadBotInfo(chat).catch(console.error);
  });
  drawKeyboard();
  drawMenu();
}
