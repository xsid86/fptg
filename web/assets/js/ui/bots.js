import { el, clear, qs } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { openMenu } from '../util/menu.js';
import { copyText } from '../util/clipboard.js';
import { openLink } from './links.js';
import { store } from '../core/store.js';
import { fillAvatar } from '../util/avatar.js';

// Работа с ботами: кнопки под сообщениями, клавиатура над полем ввода,
// команды, мини-приложения (Mini Apps).
//
// Мини-приложение открывается НЕ здесь, а отдельным окном (miniapp.pas):
// ходовые приложения запрещают показ во фрейме чужого сайта. Страница
// только просит webapp.open и передаёт цвета своей темы.
//
// Что за кнопки и как их нажимать — по td_api.tl (TDLib 1.8.67); мост —
// bot.callback / bot.info / bot.userChat в webapi.pas, кнопки приходят
// уже разобранными (KeyboardRowsJson): text, kind и то, что нужно виду.

let hooks = {};
let composer = null;
let kbBox = null;          // клавиатура над полем ввода
let kbToggle = null;       // показать / спрятать её
let menuBtn = null;        // команды бота
let keyboard = null;       // последняя клавиатура чата ({msgId, rows, oneTime})
const hiddenKb = new Set();   // msgId клавиатур, которые спрятали (или одноразовые после нажатия)
let botInfo = null;        // {commands, menuButton} открытого бота
let infoFor = null;        // для какого чата botInfo
let input = null;          // поле ввода композера
let inlineBox = null;      // результаты инлайн-запроса над полем ввода
let inlineTimer = 0;
let inlineAsked = 0;       // номер запроса: ответ на устаревший текст отбрасывается
let pendingInline = null;  // {chatId, text}: подставить после перехода в чат

// Сообщения человеку — уведомлением вверху окна (ui/notices.js), а не в
// статусной строке.
const notify = (text) => hooks.notice(text);

// Цвета темы страницы под именами themeParameters (td_api.tl) — их
// получит мини-приложение. Из CSS-переменных, которые и красят страницу.
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

/** source: inline (msg — сообщение с кнопкой), menu, keyboard (buttonText). */
async function openApp(source, url, msg, buttonText = '') {
  try {
    await hooks.call('webapp.open', {
      source,
      url,
      msgId: msg ? String(msg.id) : '',
      buttonText,
      title: (source === 'inline' && msg?.senderName) || store.activeChat?.title || 'Mini App',
      theme: pageTheme(),
    });
  } catch (error) {
    hooks.report(error);
  }
}

/** Ответ бота с show_alert — окно с OK, как у нативного клиента. */
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
 * Окно выбора для кнопок-запросов: свои чаты нужного вида, поиск,
 * галочки (до max) или выбор одного. Resolve — выбранные чаты или null.
 */
function pickChats({ title, candidates, max }) {
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
      // Дошли до предела — остальные галочки неактивны.
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
    dialog.append(
      el('p', { class: 'confirm__text' }, title),
      many ? el('p', { class: 'confirm__note' }, `Up to ${max}`) : null,
      el('label', { class: 'field share__search' }, search),
      list,
      el('div', { class: 'confirm__buttons' },
        el('button', { class: 'btn confirm__button', type: 'button', onclick: () => dialog.close() }, 'Cancel'),
        send));
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

/** Да / нет — то же окно подтверждения. */
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
  // Боты: false — нельзя, true — только боты, нет поля — без разницы.
  const kinds = button.bots === true ? ['bot']
    : button.bots === false ? ['private'] : ['private', 'bot'];
  const picked = await pickChats({
    title: button.text.trim(),
    candidates: store.chats.filter((c) => kinds.includes(c.kind)),
    max: Math.max(1, button.max || 1),
  });
  if (!picked?.length) return;
  try {
    // У личного чата id совпадает с id пользователя.
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
// «@бот запрос» в поле ввода — бот отвечает списком результатов
// (getInlineQueryResults), клик отправляет выбранный в чат
// (sendInlineQueryResultMessage). Как у нативного клиента: запрос
// уходит, только когда после имени есть пробел, и с паузой в наборе.
const INLINE_RE = /^@([A-Za-z0-9_]{3,32}) ([\s\S]*)$/;  // @gif, @vid, @pic — три буквы
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
  // Как будто набрали руками: и инлайн-режим, и высота поля это видят.
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
 * Кнопка switchInline: «@бот запрос» — в этот чат или в выбранный
 * (виды чатов — какие разрешил бот).
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

/** Нажатие кнопки — инлайн (под сообщением) или клавиатуры (msg = null). */
async function press(msg, button) {
  switch (button.kind) {
    case 'callback': {
      let answer;
      try {
        answer = await hooks.call('bot.callback', { id: String(msg.id), data: button.data });
      } catch {
        return;            // бот не ответил вовремя — молчим, как и клиент
      }
      if (answer?.text) {
        if (answer.alert) showAlert(answer.text);
        else notify(answer.text);
      }
      if (answer?.url) openLink(answer.url);
      return;
    }
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
      // Под сообщением — inline; на клавиатуре над полем ввода (msg нет) —
      // keyboard: данные такого приложения уходят боту от имени кнопки.
      if (msg) await openApp('inline', button.url, msg);
      else await openApp('keyboard', button.url, null, button.text);
      return;
    // Кнопки-запросы — только на клавиатуре над полем ввода; их
    // источник — сообщение с этой клавиатурой.
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
  return el('button', {
    class: `${cls} is-${button.kind}`,
    type: 'button',
    title: button.kind === 'url' ? button.url : '',
    onclick: (event) => {
      event.stopPropagation();
      press(msg, button).catch(console.error);
    },
  }, el('span', { class: `${cls}-text` }, button.text),
  button.kind === 'url' || button.kind === 'webapp'
    ? icon(button.kind === 'url' ? 'link' : 'dots', `${cls}-mark icon--sm`) : null);
}

/** Инлайн-кнопки под сообщением — зовёт message.js. */
export function renderInlineKeyboard(msg) {
  return el('div', { class: 'message__keyboard' },
    ...msg.keyboard.map((row) => el('div', { class: 'message__kb-row' },
      ...row.map((b) => buttonNode(msg, b, 'message__kb-btn')))));
}

// ----------------------------------------------- клавиатура над полем
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
        // Одноразовая — после нажатия прячется.
        node.addEventListener('click', () => {
          hiddenKb.add(keyboard.msgId);
          drawKeyboard();
        });
      }
      return node;
    }))));
}

function setKeyboard(next) {
  const same = keyboard && next && keyboard.msgId === next.msgId
    && JSON.stringify(keyboard.rows) === JSON.stringify(next.rows);
  if (same) return;
  keyboard = next ?? null;
  drawKeyboard();
}

// --------------------------------------------------------- команды
// Кнопка меню бота: если бот задал мини-приложение (botMenuButton) — она
// с его текстом и открывает приложение, как у нативного клиента; иначе —
// Menu со списком команд.
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
 * composerNode — #composer: клавиатура встаёт над полем ввода, кнопки
 * (Menu и переключатель клавиатуры) — в начало правой группы.
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
    // Переход по кнопке switchInline: текст — в поле уже нового чата.
    if (pendingInline && chat?.id === pendingInline.chatId) {
      const { text } = pendingInline;
      pendingInline = null;
      setTimeout(() => setComposerText(text), 0);
    }
  });
  // Строка чата бывает уточнена позже (чат не из списка) — вид станет
  // известен только тогда.
  on('store:active-row', (chat) => {
    if (chat?.id !== infoFor) loadBotInfo(chat).catch(console.error);
  });
  drawKeyboard();
  drawMenu();
}
