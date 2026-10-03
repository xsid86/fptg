import { el, clear } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { fileSize } from '../util/format.js';

// Настройки приложения.
//
// Значения живут на сервере (config.ini, владелец — tdcore), страница
// их только показывает и отправляет по одному. Каждое изменение
// сохраняется сразу, кнопки «Сохранить» нет: ответ сервера — это уже
// зажатое значение, и поле показывает именно его, так что 500 при
// пределе 20 тут же превращается в 20 у всех открытых страниц.
//
// Раскладка как у нативного окна настроек: разделы слева, содержимое
// раздела справа. Окно — модальный <dialog>, растянутый на всё окно
// приложения с отступом 32px (см. blocks/_settings.scss).

const SECTIONS = [
  { id: 'general', label: 'General', icon: 'settings', render: renderGeneral },
  { id: 'notifications', label: 'Notifications', icon: 'bell', render: renderNotifications },
  { id: 'downloads', label: 'Downloads', icon: 'download', render: renderDownloads },
  { id: 'autodownload', label: 'Auto download', icon: 'image', render: renderAutoDownload },
  { id: 'storage', label: 'Storage', icon: 'archive', render: renderStorage },
];

let dialog = null;
let opener = null;
let hooks = {};
let nav = null;
let pane = null;
let current = SECTIONS[0].id;
let data = null;      // последний ответ settings.get / событие settings
let storage = null;   // последний ответ storage.get / событие storage
let storageView = null;
let nextId = 0;

const uid = () => `settings-${++nextId}`;

// ------------------------------------------------------------ controls
/** Строка раздела: подпись и пояснение слева, элемент управления справа. */
function row(id, label, hint, control) {
  return el('div', { class: 'settings__row' },
    el('div', { class: 'settings__text' },
      el('label', { class: 'settings__label', htmlFor: id }, label),
      hint ? el('p', { class: 'settings__hint' }, hint) : null),
    el('div', { class: 'settings__control' }, control));
}

function group(title, ...rows) {
  return el('section', { class: 'settings__group' },
    title ? el('h3', { class: 'settings__group-title' }, title) : null,
    ...rows);
}

function switchControl(id, checked, onCommit) {
  const input = el('input', {
    class: 'switch__input', type: 'checkbox', id, checked,
    onchange: () => onCommit(input.checked, input),
  });
  return el('span', { class: 'switch' }, input, el('span', { class: 'switch__track' }));
}

/**
 * Число с единицей измерения. Отправляется по change (Enter или уход из
 * поля), а не на каждый ввод: иначе набор «100» сохранил бы сначала 1.
 */
function numberControl(id, { value, min, max, unit }, onCommit) {
  const input = el('input', {
    class: 'field__input settings__number', type: 'number', id,
    min: String(min), max: String(max), step: '1', value: String(value),
    onchange: () => {
      const v = Math.round(Number(input.value));
      if (input.value === '' || !Number.isFinite(v)) {
        input.value = String(value);
        return;
      }
      onCommit(v, input);
    },
  });
  return el('label', { class: 'field settings__field' },
    input,
    unit ? el('span', { class: 'settings__unit' }, unit) : null);
}

// Углы экрана — коды те же, что у сервера (DESKNOTIFY_CORNERS).
const CORNERS = [
  { id: 'tl', label: 'Top left' },
  { id: 'tr', label: 'Top right' },
  { id: 'bl', label: 'Bottom left' },
  { id: 'br', label: 'Bottom right' },
];

/**
 * Выбор угла: схема экрана, в каждом углу — карточка в миниатюре, как
 * в Telegram Desktop. Выбранная — цвета акцента.
 */
function cornerControl(id, value, onCommit) {
  const box = el('div', {
    class: 'settings__corners', id, role: 'group', 'aria-label': 'Screen corner',
  }, ...CORNERS.map((c) => el('button', {
    class: `settings__corner settings__corner--${c.id}`,
    type: 'button',
    title: c.label,
    'aria-label': c.label,
    'data-corner': c.id,
    onclick: () => onCommit(c.id, box),
  })));
  markCorner(box, value);
  return box;
}

function markCorner(box, value) {
  for (const spot of box.children) {
    const on = spot.dataset.corner === value;
    spot.classList.toggle('is-active', on);
    spot.setAttribute('aria-pressed', String(on));
  }
}

function textControl(id, value, onCommit) {
  const input = el('input', {
    class: 'field__input', type: 'text', id, value, autocomplete: 'off',
    onchange: () => onCommit(input.value.trim(), input),
  });
  return el('label', { class: 'field settings__field settings__field--wide' }, input);
}

// ------------------------------------------------------------- saving
/**
 * Одна настройка на сервер. Поле, из которого пришло значение, получает
 * назад то, что сервер реально сохранил; остальной раздел обновит
 * событие settings, которое сервер шлёт всем страницам.
 */
async function commit(args, input, read) {
  try {
    data = await hooks.load('settings.set', args);
    if (input && read) read(input, data);
  } catch (error) {
    hooks.report(error);
    // Отказ (например, пустое имя устройства) — вернуть поле к тому,
    // что действует, а не оставлять в нём несохранённое.
    if (input && read && data) read(input, data);
  }
}

// ----------------------------------------------------------- sections
function renderGeneral() {
  const tray = uid();
  const device = uid();
  return [
    group(null,
      row(tray, 'Close to tray',
        'The close button hides the window and keeps the app running. '
        + 'Quit from the tray icon.',
        switchControl(tray, data.closeToTray, (checked, input) => commit(
          { key: 'closeToTray', value: checked }, input,
          (node, d) => { node.checked = d.closeToTray; }))),
      row(device, 'Device name',
        'How this app is listed in Telegram under Active sessions. '
        + 'Takes effect the next time an account signs in.',
        textControl(device, data.deviceModel, (value, input) => commit(
          { key: 'deviceModel', value }, input,
          (node, d) => { node.value = d.deviceModel; })))),
  ];
}

function renderNotifications() {
  const n = data.notify;
  const enabled = uid();
  const corner = uid();
  const limit = uid();
  const titleFont = uid();
  const textFont = uid();
  const font = (id, key, value) => numberControl(id,
    { value, min: n.fontMin, max: n.fontMax, unit: 'px' },
    (v, input) => commit({ key: `notify.${key}`, value: v }, input,
      (node, d) => { node.value = String(d.notify[key]); }));
  return [
    group(null,
      row(enabled, 'Desktop notifications',
        'Pop-ups for new messages in chats that are not muted. Not shown '
        + 'for the chat that is open while the window is in front.',
        switchControl(enabled, n.enabled, (checked, input) => commit(
          { key: 'notify.enabled', value: checked }, input,
          (node, d) => { node.checked = d.notify.enabled; }))),
      row(corner, 'Position',
        'The corner of the screen they appear in. A sample shows up '
        + 'there when you pick one.',
        cornerControl(corner, n.corner, (value, box) => commit(
          { key: 'notify.corner', value }, box,
          (node, d) => markCorner(node, d.notify.corner)))),
      row(limit, 'At the same time',
        `How many can be on screen at once (${n.limitMin}–${n.limitMax}). `
        + 'Older ones make way for new ones.',
        numberControl(limit, { value: n.limit, min: n.limitMin, max: n.limitMax },
          (value, input) => commit({ key: 'notify.limit', value }, input,
            (node, d) => { node.value = String(d.notify.limit); })))),
    group('Text',
      row(titleFont, 'Title size',
        `The chat name (${n.fontMin}–${n.fontMax}).`,
        font(titleFont, 'titleFont', n.titleFont)),
      row(textFont, 'Message size',
        `The message preview (${n.fontMin}–${n.fontMax}).`,
        font(textFont, 'textFont', n.textFont))),
  ];
}

function renderDownloads() {
  const d = data.downloads;
  const parallel = uid();
  const speed = uid();
  return [
    group(null,
      row(parallel, 'Parallel downloads',
        `How many files download at the same time (${d.concurrencyMin}–${d.concurrencyMax}).`,
        numberControl(parallel,
          { value: d.concurrency, min: d.concurrencyMin, max: d.concurrencyMax },
          (value, input) => commit({ key: 'downloads.concurrency', value }, input,
            (node, s) => { node.value = String(s.downloads.concurrency); }))),
      row(speed, 'Speed limit',
        '0 means no limit.',
        numberControl(speed,
          { value: d.speedKb, min: d.speedKbMin, max: d.speedKbMax, unit: 'KB/s' },
          (value, input) => commit({ key: 'downloads.speedKb', value }, input,
            (node, s) => { node.value = String(s.downloads.speedKb); })))),
  ];
}

/**
 * Сетка «вид медиа × вид чата». Таблицей, а не группой флажков на
 * каждый вид медиа, как в нативном окне: ширины у страницы хватает, и
 * столбец читается как «что качается в группах» с одного взгляда.
 */
function renderAutoDownload() {
  const a = data.autodownload;
  const enabled = new Set(a.on);
  const head = el('tr', {},
    el('th', { class: 'settings__grid-corner', scope: 'col' },
      el('span', { class: 'u-sr-only' }, 'Media')),
    ...a.chats.map((c) => el('th', { scope: 'col' }, c.label)));
  const body = a.media.map((m) => el('tr', {},
    el('th', { scope: 'row' }, m.label),
    ...a.chats.map((c) => {
      const key = `${m.kind}.${c.kind}`;
      const box = el('input', {
        class: 'settings__check', type: 'checkbox', checked: enabled.has(key),
        title: `${m.label} in ${c.label.toLowerCase()}`,
        onchange: () => commit(
          { key: 'autodownload', media: m.kind, chat: c.kind, value: box.checked },
          box, (node, s) => { node.checked = s.autodownload.on.includes(key); }),
      });
      return el('td', {}, box);
    })));
  return [
    el('p', { class: 'settings__intro' },
      'Files that download by themselves as soon as a message with them '
      + 'comes into view. Everything else waits for a click.'),
    el('div', { class: 'settings__grid-wrap' },
      el('table', { class: 'settings__grid' },
        el('thead', {}, head),
        el('tbody', {}, ...body))),
  ];
}

function storageStatus(s) {
  if (s.busy) return 'Working…';
  if (s.error) return s.error;
  if (s.freedCount > 0) return `Freed ${fileSize(s.freed)} in ${s.freedCount} files`;
  return '';
}

/** Обновляет только цифры кэша — поля ввода при этом не трогаются. */
function updateStorage() {
  if (!storageView || !storage) return;
  const s = storage;
  storageView.usage.textContent = s.known
    ? `${fileSize(s.filesSize)} in ${s.fileCount} files`
    : 'Not measured yet';
  storageView.database.textContent = s.known
    ? `Database ${fileSize(s.databaseSize)}, log ${fileSize(s.logSize)}`
    : '';
  storageView.status.textContent = storageStatus(s);
  storageView.cleanup.disabled = !!s.busy;
}

function renderStorage() {
  const c = data.cache;
  const limit = uid();
  const ttl = uid();
  storageView = {
    usage: el('div', { class: 'settings__figure u-tabular' }),
    database: el('div', { class: 'settings__hint u-tabular' }),
    status: el('span', { class: 'settings__hint', role: 'status' }),
    cleanup: el('button', {
      class: 'btn btn--primary', type: 'button',
      onclick: async () => {
        try {
          storage = await hooks.load('storage.cleanup');
          updateStorage();
        } catch (error) {
          hooks.report(error);
        }
      },
    }, 'Clean up now'),
  };
  // Цифры двигаются, пока приложение работает, поэтому спрашиваются при
  // каждом заходе в раздел; свежие приедут событием storage.
  hooks.load('storage.get')
    .then((s) => { storage = s; updateStorage(); })
    .catch(hooks.report);
  updateStorage();

  return [
    group('Media cache',
      el('div', { class: 'settings__row' },
        el('div', { class: 'settings__text' }, storageView.usage, storageView.database),
        el('div', { class: 'settings__control' }, storageView.cleanup)),
      el('div', { class: 'settings__status' }, storageView.status)),
    group('Limits',
      row(limit, 'Cache size limit',
        'Oldest files go first once the cache grows past this. 0 means no limit.',
        numberControl(limit,
          { value: c.limitMb, min: c.limitMbMin, max: c.limitMbMax, unit: 'MB' },
          (value, input) => commit({ key: 'cache.limitMb', value }, input,
            (node, s) => { node.value = String(s.cache.limitMb); }))),
      row(ttl, 'Delete files older than',
        '0 keeps files regardless of age.',
        numberControl(ttl,
          { value: c.ttlDays, min: c.ttlDaysMin, max: c.ttlDaysMax, unit: 'days' },
          (value, input) => commit({ key: 'cache.ttlDays', value }, input,
            (node, s) => { node.value = String(s.cache.ttlDays); }))),
      el('p', { class: 'settings__hint' },
        'Limits apply at the next start, or right away with Clean up now.')),
  ];
}

// -------------------------------------------------------------- frame
function renderNav() {
  clear(nav).append(
    el('h2', { class: 'settings__title' }, 'Settings'),
    ...SECTIONS.map((s) => el('button', {
      class: `settings__tab${s.id === current ? ' is-active' : ''}`,
      type: 'button',
      'aria-current': s.id === current ? 'page' : null,
      onclick: () => select(s.id),
    }, icon(s.icon, 'icon--sm'), el('span', {}, s.label))));
}

function renderPane() {
  const section = SECTIONS.find((s) => s.id === current) ?? SECTIONS[0];
  storageView = null;
  clear(pane).append(
    el('header', { class: 'settings__head' },
      el('h2', { class: 'settings__heading' }, section.label),
      el('button', {
        class: 'btn btn--icon', type: 'button', title: 'Close',
        onclick: close,
      }, icon('close'), el('span', { class: 'u-sr-only' }, 'Close'))),
    el('div', { class: 'settings__body' },
      ...(data ? section.render() : [el('p', { class: 'settings__hint' }, 'Loading…')])));
}

function select(id) {
  current = id;
  renderNav();
  renderPane();
}

async function open() {
  if (dialog.open) return;
  renderNav();
  renderPane();
  dialog.showModal();
  try {
    data = await hooks.load('settings.get');
    renderPane();
  } catch (error) {
    hooks.report(error);
  }
}

function close() {
  dialog.close();
}

/**
 * Пока фокус в поле этой страницы, раздел не перестраивается: иначе
 * чужое изменение (из другой вкладки или нативного окна) выбило бы
 * курсор из поля, в котором сейчас печатают.
 */
function editing() {
  const active = document.activeElement;
  return !!active && pane.contains(active) && active.matches('input[type="text"], input[type="number"]');
}

export function mountSettings(node, button, options) {
  dialog = node;
  opener = button;
  hooks = options;
  nav = el('nav', { class: 'settings__nav', 'aria-label': 'Settings sections' });
  pane = el('div', { class: 'settings__pane' });
  dialog.append(el('div', { class: 'settings__window' }, nav, pane));

  opener.addEventListener('click', open);
  // Клик мимо окна — по самому <dialog>, который занимает весь экран
  // вокруг него, — закрывает, как у любого модального слоя.
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) close();
  });
  dialog.addEventListener('close', () => {
    storageView = null;
    opener.focus();
  });

  on('srv:settings', (payload) => {
    data = payload;
    if (dialog.open && !editing()) renderPane();
  });
  on('srv:storage', (payload) => {
    storage = payload;
    updateStorage();
  });
}
