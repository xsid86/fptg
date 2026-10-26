import { el, clear, qs } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { formDialog, field, checkRow, openPollDialog, openAttachBot, geoErrorText } from './bots.js';

// The paperclip menu — as in the native client: it appears on hovering the
// attach button. A click on the paperclip itself still opens the file
// choice (ui/composer.js). A touch screen has no hover: there a tap on the
// paperclip opens and closes the menu, and the files come from its items.
//
// Items: photo or video (media), document, poll, checklist, article,
// location, music — and the attachment menu bots (attach.bots, for example
// "Wallet"), which open as a Mini App. What content goes for each — per
// td_api.tl of commit d1085f9, see webapi.pas.

const SHOW_DELAY_MS = 150;
const HIDE_DELAY_MS = 300;
const CHECKLIST_TASKS_MAX = 30;   // getOption checklist_task_count_max (a live log)

/** No hover (a touch screen): the paperclip works by taps (ui/composer.js too). */
export const NO_HOVER = window.matchMedia('(hover: none)');

let hooks = {};
let menu = null;
let botsBox = null;
let picker = null;
let pickMode = 'document';
let showTimer = 0;
let hideTimer = 0;

function show() {
  clearTimeout(hideTimer);
  if (!hooks.canCompose() || !menu.hidden) return;
  clearTimeout(showTimer);
  showTimer = setTimeout(() => {
    menu.hidden = false;
    loadBots();
  }, SHOW_DELAY_MS);
}

function hideSoon() {
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  hideTimer = setTimeout(() => { menu.hidden = true; }, HIDE_DELAY_MS);
}

function hideNow() {
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  menu.hidden = true;
}

/** Files of the given kind: media | document | audio — into the send dialog. */
function pickFiles(accept, mode) {
  pickMode = mode;
  picker.accept = accept;
  picker.click();
}

async function loadBots() {
  clear(botsBox);
  let bots = [];
  try {
    bots = await hooks.call('attach.bots');
  } catch {
    return;
  }
  botsBox.hidden = !bots.length;
  botsBox.append(...bots.map((b) => item('bot', b.name, () => openAttachBot(b.id, b.name))));
}

function item(iconName, label, run) {
  return el('button', {
    class: 'attach-menu__item', type: 'button', role: 'menuitem',
    onclick: () => {
      hideNow();
      run();
    },
  }, icon(iconName), el('span', {}, label));
}

// ------------------------------------------------------------ checklist
async function checklistDialog() {
  const title = field({ type: 'text', placeholder: 'Title', maxLength: 255 });
  const list = el('div', { class: 'bots__options' });
  const add = () => {
    if (list.children.length >= CHECKLIST_TASKS_MAX) return;
    list.append(field({ type: 'text', placeholder: `Task ${list.children.length + 1}`, maxLength: 200 }));
    more.disabled = list.children.length >= CHECKLIST_TASKS_MAX;
  };
  const more = el('button', { class: 'btn bots__add', type: 'button', onclick: add }, 'Add a task');
  add();
  add();
  const othersAdd = checkRow('Others can add tasks', false);
  const othersMark = checkRow('Others can mark tasks as done', true);
  const tasks = () => [...list.children].map((n) => n.value.trim()).filter(Boolean);
  const yes = await formDialog({
    text: 'New checklist',
    body: [title, list, more, othersAdd.node, othersMark.node],
    ok: 'Send',
    check: () => {
      if (!title.value.trim()) return 'Enter a title';
      if (!tasks().length) return 'Add at least one task';
      return '';
    },
  });
  if (!yes) return;
  try {
    await hooks.call('message.sendChecklist', {
      title: title.value.trim(), tasks: tasks(),
      othersAdd: othersAdd.box.checked, othersMark: othersMark.box.checked,
    });
  } catch (error) {
    hooks.report(error);
  }
}

// -------------------------------------------------------------- article
/**
 * An article's text — into blocks: an empty line — a new paragraph; "# ",
 * "## ", "### " — headings; "- " — list items; "> " — a quote; "---" — a
 * divider. The article's title — as the first block.
 */
function articleBlocks(title, text) {
  const blocks = [];
  if (title) blocks.push({ type: 'heading', size: 1, text: title });
  let para = [];
  let list = [];
  const flush = () => {
    if (para.length) blocks.push({ type: 'paragraph', text: para.join('\n') });
    if (list.length) blocks.push({ type: 'list', items: list });
    para = [];
    list = [];
  };
  for (const raw of text.split('\n')) {
    const line = raw.trimEnd();
    const heading = /^(#{1,3})\s+(.+)$/.exec(line);
    if (!line.trim()) {
      flush();
    } else if (line.trim() === '---') {
      flush();
      blocks.push({ type: 'divider' });
    } else if (heading) {
      flush();
      blocks.push({ type: 'heading', size: heading[1].length + 1, text: heading[2] });
    } else if (/^[-*]\s+/.test(line)) {
      if (para.length) flush();
      list.push(line.replace(/^[-*]\s+/, ''));
    } else if (/^>\s?/.test(line)) {
      flush();
      blocks.push({ type: 'quote', text: line.replace(/^>\s?/, '') });
    } else {
      if (list.length) flush();
      para.push(line);
    }
  }
  flush();
  return blocks;
}

async function articleDialog() {
  const title = field({ type: 'text', placeholder: 'Title' });
  const body = el('textarea', {
    class: 'field__input bots__input attach-menu__article', rows: 10,
    placeholder: 'Text. A blank line starts a new paragraph; # heading, '
      + '- list item, > quote, --- divider.',
  });
  const yes = await formDialog({
    text: 'New article',
    body: [title, body],
    ok: 'Send',
    check: () => (title.value.trim() || body.value.trim() ? '' : 'The article is empty'),
  });
  if (!yes) return;
  try {
    await hooks.call('message.sendArticle', {
      blocks: articleBlocks(title.value.trim(), body.value),
    });
  } catch (error) {
    hooks.report(error);
  }
}

// ------------------------------------------------------------- location
async function locationDialog() {
  const lat = field({ type: 'number', step: 'any', min: '-90', max: '90', placeholder: 'Latitude' });
  const lon = field({ type: 'number', step: 'any', min: '-180', max: '180', placeholder: 'Longitude' });
  let accuracy = 0;
  const status = el('p', { class: 'settings__hint' });
  const mine = el('button', {
    class: 'btn bots__add', type: 'button',
    onclick: () => {
      if (!navigator.geolocation) {
        status.textContent = 'Location is not available';
        return;
      }
      status.textContent = 'Locating…';
      navigator.geolocation.getCurrentPosition((pos) => {
        lat.value = String(pos.coords.latitude);
        lon.value = String(pos.coords.longitude);
        accuracy = pos.coords.accuracy || 0;
        status.textContent = '';
      }, (error) => {
        status.textContent = geoErrorText(error);
      }, { enableHighAccuracy: true, timeout: 15000 });
    },
  }, 'Use my location');
  const valid = () => {
    const a = Number(lat.value);
    const b = Number(lon.value);
    return lat.value !== '' && lon.value !== '' && a >= -90 && a <= 90 && b >= -180 && b <= 180;
  };
  const yes = await formDialog({
    text: 'Send a location',
    body: [lat, lon, mine, status],
    ok: 'Send',
    check: () => (valid() ? '' : 'Enter a latitude and a longitude'),
  });
  if (!yes) return;
  try {
    await hooks.call('message.sendLocation', {
      lat: Number(lat.value), lon: Number(lon.value), accuracy,
    });
  } catch (error) {
    hooks.report(error);
  }
}

// ---------------------------------------------------------------- mount
export function mountAttachMenu(composerNode, options) {
  hooks = options ?? {};
  const button = qs('.composer__attach', composerNode);
  if (!button) return;

  picker = el('input', { type: 'file', multiple: true, hidden: true });
  picker.addEventListener('change', () => {
    const files = [...picker.files];
    picker.value = '';
    if (files.length) emit('ui:attach', { files, mode: pickMode });
  });

  botsBox = el('div', { class: 'attach-menu__bots', hidden: true });
  menu = el('div', { class: 'attach-menu', role: 'menu', hidden: true },
    item('image', 'Photo or video', () => pickFiles('image/*,video/*', 'media')),
    item('file', 'Document', () => pickFiles('', 'document')),
    item('poll', 'Poll', () => openPollDialog({}, 'message.sendPoll')),
    item('check', 'Checklist', checklistDialog),
    item('bookmark', 'Article', articleDialog),
    item('pin', 'Location', locationDialog),
    item('audio', 'Music', () => pickFiles('audio/*', 'audio')),
    botsBox);

  // The wrapper is the reference point for the menu: the position is set by classes, not style.
  const wrap = el('span', { class: 'attach-menu__anchor' });
  button.replaceWith(wrap);
  wrap.append(button, menu, picker);

  for (const node of [button, menu]) {
    node.addEventListener('mouseenter', () => { if (!NO_HOVER.matches) show(); });
    node.addEventListener('mouseleave', () => { if (!NO_HOVER.matches) hideSoon(); });
  }
  button.addEventListener('click', () => {
    if (!NO_HOVER.matches) return;
    if (!menu.hidden) {
      hideNow();
    } else if (hooks.canCompose()) {
      menu.hidden = false;
      loadBots();
    }
  });
  // A tap anywhere else closes it.
  document.addEventListener('pointerdown', (event) => {
    if (!menu.hidden && NO_HOVER.matches && !wrap.contains(event.target)) hideNow();
  });
  menu.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') hideNow();
  });
}
