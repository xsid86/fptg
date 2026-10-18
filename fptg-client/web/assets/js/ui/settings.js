import { el, clear } from '../core/dom.js';
import { on } from '../core/bus.js';
import { icon } from '../util/icons.js';
import { fileSize } from '../util/format.js';
import { fillAvatar } from '../util/avatar.js';
import { openViewer, closeViewer, viewerOpen } from './viewer.js';
import { NAME_COLORS, PROFILE_COLORS } from '../util/palette.js';
import { MAP_PROVIDERS, setMapProvider } from '../util/maps.js';
import { devicePanel } from '../calls/devices.js';
import { shellSettings, postShell } from './shell.js';
import { trafficShown, setTrafficShown } from './status-bar.js';
import { ACCENTS, currentAccent, setAccent } from './theme.js';
import { uploadUrl, serverBase, currentUser, signOut } from '../core/session.js';
import {
  initKit, setPremium, row, group, switchControl, numberControl, textControl, uid, navRow,
  selectControl,
} from './setkit.js';
import { getPref, setPref } from '../util/prefs.js';
import { renderPrivacySecurity } from './setprivacy.js';
import { renderNotifyScopes, renderAcceptCalls } from './setnotify.js';
import { renderChatSettings as chatSettingsParts, renderPower, renderLanguage } from './setchats.js';
import { renderFolders } from './setfolders.js';
import { renderPremium, renderStars, renderGift } from './setpremium.js';
import { renderBusiness } from './setbusiness.js';
import { openProxies } from './setproxy.js';

// The application settings.
//
// The values live on the server (config.ini, owned by tdcore); the page
// only shows them and sends them one at a time. Every change is saved at
// once, there is no "Save" button: the server's answer is the already
// clamped value, and the field shows exactly that, so 500 with a limit of
// 20 turns into 20 at once on all open pages.
//
// The layout is like the native settings window: sections on the left, the
// section's content on the right. The window is a modal <dialog> stretched
// over the whole app window with a 32px margin (see blocks/_settings.scss).
//
// Sections — in the order and under the names of Telegram Desktop. Our own
// things Desktop has no separate section for (downloads, cache, the map
// service, closing to the tray, the server) — inside Advanced, as it has
// "Data and storage" and "System integration". A section may be async: the
// old content stays until the new one is ready (renderPane).
//
// Three help items are empty for now: they will be links to the project
// site with questions about fptg itself, not about Telegram.

const SECTIONS = [
  { id: 'account', label: 'My account', icon: 'person', render: renderAccount },
  { id: 'notifications', label: 'Notifications and sounds', icon: 'bell', render: renderNotifications },
  { id: 'privacy', label: 'Privacy and security', icon: 'lock', render: renderPrivacySecurity },
  { id: 'chats', label: 'Chat settings', icon: 'chat', render: renderChats },
  { id: 'folders', label: 'Folders', icon: 'folder', render: renderFolders },
  { id: 'advanced', label: 'Advanced', icon: 'settings', render: renderAdvanced },
  { id: 'calls', label: 'Speakers and camera', icon: 'mic', render: renderCalls },
  { id: 'power', label: 'Battery and animation', icon: 'battery', render: renderPower },
  { id: 'language', label: 'Language', icon: 'globe', render: renderLanguage },
  { sep: true },
  { id: 'premium', label: 'Telegram Premium', icon: 'star', render: renderPremium },
  { id: 'stars', label: 'My stars', icon: 'star', render: renderStars },
  { id: 'business', label: 'Telegram Business', icon: 'briefcase', render: renderBusiness },
  { id: 'gift', label: 'Send a gift', icon: 'gift', render: renderGift },
  { sep: true },
  { id: 'faq', label: 'Telegram FAQ', icon: 'help', render: () => [] },
  { id: 'features', label: 'Telegram Features', icon: 'bulb', render: () => [] },
  { id: 'ask', label: 'Ask a question', icon: 'chat', render: () => [] },
];
const PAGES = SECTIONS.filter((x) => !x.sep);

let dialog = null;
let opener = null;
let hooks = {};
let nav = null;
let pane = null;
let current = PAGES[0].id;
let data = null;      // the latest settings.get answer / settings event
let storage = null;   // the latest storage.get answer / storage event
let storageView = null;
// The Advanced subpage: null — the section itself, otherwise the subpage id
// (downloads, autodownload, storage, maps).
let advancedView = null;
let paneSeq = 0;

// Screen corners — the same codes as the server's (DESKNOTIFY_CORNERS).
const CORNERS = [
  { id: 'tl', label: 'Top left' },
  { id: 'tr', label: 'Top right' },
  { id: 'bl', label: 'Bottom left' },
  { id: 'br', label: 'Bottom right' },
];

/**
 * The corner choice: a screen diagram with a miniature card in each corner,
 * as in Telegram Desktop. The chosen one is in the accent colour.
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

// ------------------------------------------------------------- saving
/**
 * One setting to the server. The field the value came from gets back what
 * the server actually saved; the rest of the section is updated by the
 * settings event the server sends to all pages.
 */
async function commit(args, input, read) {
  try {
    data = await hooks.load('settings.set', args);
    if (input && read) read(input, data);
    // Closing to the tray and the cards are carried out by the window
    // (ui/shell.js); the cards changed — show a sample, like Telegram Desktop.
    shellSettings(data);
    if (String(args?.key).startsWith('notify.') && data?.notify?.enabled) {
      postShell({ t: 'notifySample' });
    }
  } catch (error) {
    hooks.report(error);
    // A refusal (for example, an empty device name) — return the field to
    // what is in effect rather than leaving the unsaved value in it.
    if (input && read && data) read(input, data);
  }
}

// ---------------------------------------------------------- my account
// The "My account" section — like the native client's "My account": photo,
// name, bio, username, phone, personal channel, birthday. The data is not
// from settings.get but straight from TDLib (account.get: getMe +
// getUserFullInfo), and every field saves itself on change.

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'];
const USERNAME_HINTS = {
  ok: 'This username is available.',
  invalid: 'Usernames can use a–z, 0–9 and underscores, at least 5 characters.',
  occupied: 'This username is already taken.',
  purchasable: 'This username is for sale on Fragment.',
  tooMany: 'You own too many public links already.',
  unavailable: 'This username cannot be used.',
};

let account = null;     // the latest account.get answer
let accountLoading = false;
// Inside the section — the main view or the colour choice (like the
// native client's separate "Color preview" screen).
let accountView = 'main';
let colorTab = 'profile';
let pick = null;        // { accent, profile } — chosen, not yet saved

/**
 * A small window over the settings: text and buttons. A nested modal
 * <dialog> goes into the top layer above the settings window. The same
 * classes as the message deletion confirmation (blocks/_confirm.scss).
 */
function alertBox(text, buttons = []) {
  const box = el('dialog', { class: 'confirm' });
  const close = () => box.close();
  const list = buttons.length ? buttons : [{ label: 'OK' }];
  box.append(el('p', { class: 'confirm__text' }, text),
    el('div', { class: 'confirm__buttons' },
      ...(buttons.length ? [el('button', {
        class: 'btn confirm__button', type: 'button', onclick: close,
      }, 'Cancel')] : []),
      ...list.map((b) => el('button', {
        class: 'btn confirm__button', type: 'button',
        onclick: () => { close(); b.run?.(); },
      }, b.label))));
  box.addEventListener('click', (event) => {
    if (event.target === box) close();
  });
  box.addEventListener('close', () => box.remove());
  document.body.append(box);
  box.showModal();
  box.querySelector('.confirm__buttons button:last-child')?.focus();
}

/**
 * Own avatars in the viewer: "Set as main" and "Delete" on the top bar. The
 * viewer is hung inside the settings window — see openViewer.
 */
async function openGallery(a) {
  let answer;
  try {
    answer = await hooks.load('account.photos', { userId: a.id });
  } catch (error) {
    hooks.report(error);
    return;
  }
  // '-' — the file did not download; there is nothing to show such a slide with.
  const photos = answer.photos.filter((p) => p.url && p.url !== '-');
  if (!photos.length) return;
  // An animated one — as a looped video without sound, the picture as the
  // poster and the strip thumbnail (the viewer plays GIFs the same way).
  const slides = photos.map((p) => (p.animUrl && p.animUrl !== '-'
    ? {
      id: p.id,
      kind: 'animation',
      media: { url: p.animUrl, thumbUrl: p.url, thumb: p.url, w: p.animSize || p.w, h: p.animSize || p.h },
    }
    : {
      id: p.id,
      kind: 'photo',
      media: { fullUrl: p.url, url: p.url, thumb: p.thumb, w: p.w, h: p.h, fullW: p.w, fullH: p.h },
    }));
  openViewer(slides, 0, {
    container: dialog,
    actions: [
      {
        name: 'photo-main',
        title: 'Set as main',
        onClick: (i) => {
          // The first one is the main one.
          if (i <= 0 || !photos[i]) return;
          closeViewer();
          saveAccount({ key: 'photoMain', photoId: photos[i].id });
        },
      },
      {
        name: 'photo-delete',
        title: 'Delete',
        onClick: (i) => {
          if (!photos[i]) return;
          alertBox('Delete this photo?', [{
            label: 'Delete',
            run: () => {
              closeViewer();
              saveAccount({ key: 'photoDelete', photoId: photos[i].id });
            },
          }]);
        },
      },
    ],
  });
}

/** A colour circle: the halves — --swatch-1/2, the dot — --swatch-3 (base/_palette.scss). */
function swatchGrid(ids, prefix, chosen, onPick, extraClass = '') {
  return el('div', { class: `color-grid${extraClass ? ` ${extraClass}` : ''}`, role: 'radiogroup' },
    ...ids.map((id) => el('button', {
      class: `color-swatch swatch-${prefix}${id}${id === chosen ? ' is-active' : ''}`,
      type: 'button',
      role: 'radio',
      'aria-checked': String(id === chosen),
      'aria-label': `Color ${id}`,
      onclick: () => onPick(id),
    })));
}

function renderColors(a) {
  if (!pick) pick = { accent: a.accentId, profile: a.profileAccentId };
  const tab = (id, label) => el('button', {
    class: `color-tabs__tab${colorTab === id ? ' is-active' : ''}`,
    type: 'button', role: 'tab', 'aria-selected': String(colorTab === id),
    onclick: () => { colorTab = id; renderPane(); },
  }, label);
  const avatar = el('span', { class: `avatar color-preview__avatar accent-${a.color}` });
  fillAvatar(avatar, { title: a.title, avatar: a.avatar, avatarThumb: a.avatarThumb });

  let preview;
  let grid;
  let extra = null;
  let hint;
  if (colorTab === 'profile') {
    preview = el('div', {
      class: `color-preview color-preview--profile${pick.profile >= 0 ? ` swatch-p${pick.profile} has-color` : ''}`,
    }, avatar, el('div', { class: 'color-preview__title' }, a.title));
    grid = swatchGrid(PROFILE_COLORS, 'p', pick.profile, (id) => { pick.profile = id; renderPane(); });
    extra = el('button', {
      class: 'btn settings__link', type: 'button',
      onclick: () => { pick.profile = -1; renderPane(); },
    }, 'Reset profile color');
    hint = 'The color of your profile page.';
  } else {
    preview = el('div', { class: `color-preview color-preview--name accent-a${pick.accent} swatch-a${pick.accent}` },
      avatar,
      el('div', { class: 'color-preview__bubble' },
        el('div', { class: 'color-preview__sender' }, a.title),
        el('div', { class: 'color-preview__quote' },
          el('div', { class: 'color-preview__sender' }, a.title),
          el('div', {}, 'Your original message')),
        el('div', {}, 'Your name and replies to your messages are shown in this color.')));
    grid = swatchGrid(NAME_COLORS, 'a', pick.accent, (id) => { pick.accent = id; renderPane(); });
    hint = 'Your name, the links you send and quotes of your messages in replies get this color.';
  }

  const changed = pick.accent !== a.accentId || pick.profile !== a.profileAccentId;
  const apply = el('button', {
    class: 'btn btn--primary color-apply', type: 'button', disabled: !a.premium || !changed,
    onclick: async () => {
      apply.disabled = true;
      try {
        if (pick.accent !== a.accentId) {
          await hooks.load('account.set', { key: 'accent', value: pick.accent, emoji: a.accentEmoji });
        }
        if (pick.profile !== a.profileAccentId) {
          await hooks.load('account.set', { key: 'profileAccent', value: pick.profile, emoji: a.profileEmoji });
        }
      } catch (error) {
        hooks.report(error);
      }
      accountView = 'main';
      pick = null;
      await reloadAccount();
    },
  }, 'Apply');

  return [
    el('button', {
      class: 'btn settings__back', type: 'button',
      onclick: () => { accountView = 'main'; pick = null; renderPane(); },
    }, icon('chevron-left'), 'My account'),
    el('div', { class: 'color-tabs', role: 'tablist' }, tab('profile', 'Profile'), tab('name', 'Name')),
    preview,
    grid,
    extra,
    el('p', { class: 'settings__hint' }, hint),
    el('p', { class: 'settings__hint' }, a.premium
      ? 'Background emoji and gift styles are set from a phone app for now.'
      : 'Colors can be changed with Telegram Premium.'),
    apply,
  ];
}

/** One file per POST /upload (the token — core/session.js); the answer is the upload id. */
async function uploadFile(file) {
  const res = await fetch(await uploadUrl(file.name), { method: 'POST', body: file });
  const answer = (await res.text()).trim();
  if (!res.ok || !answer) throw new Error(answer || `Upload failed (${res.status})`);
  return answer;
}

/** An account field to the server, then the section is re-read whole. */
async function saveAccount(args) {
  try {
    await hooks.load('account.set', args);
  } catch (error) {
    hooks.report(error);
  }
  await reloadAccount();
}

async function reloadAccount() {
  if (accountLoading) return;
  accountLoading = true;
  try {
    account = await hooks.load('account.get');
  } catch (error) {
    hooks.report(error);
    return;
  } finally {
    accountLoading = false;
  }
  if (current === 'account' && dialog.open && !editing()) renderPane();
}

function accountHeader(a) {
  const avatar = el('span', { class: `avatar settings__avatar accent-${a.color}` });
  // avatarAnim — an animated avatar (<video>, util/avatar.js).
  fillAvatar(avatar, {
    id: a.id, title: a.title, avatar: a.avatar, avatarThumb: a.avatarThumb, avatarAnim: a.avatarAnim,
  });
  // A click on the avatar — the gallery of own photos, as in the native client.
  const avatarBtn = el('button', {
    class: 'settings__avatar-btn', type: 'button', title: 'Your photos',
    onclick: () => openGallery(a),
  }, avatar);
  const picker = el('input', {
    type: 'file', accept: 'image/jpeg,image/png,image/webp', hidden: true,
    onchange: async () => {
      const file = picker.files?.[0];
      if (!file) return;
      try {
        const id = await uploadFile(file);
        await saveAccount({ key: 'photo', upload: id });
      } catch (error) {
        hooks.report(error);
      }
    },
  });
  const change = el('button', {
    class: 'btn btn--icon settings__photo', type: 'button', title: 'Change photo',
    onclick: () => picker.click(),
  }, icon('image'), el('span', { class: 'u-sr-only' }, 'Change photo'));
  return el('div', { class: 'settings__profile' },
    el('div', { class: 'settings__avatar-wrap' }, avatarBtn, change, picker),
    el('div', { class: 'settings__profile-name' }, a.title || '(no name)'),
    el('div', { class: 'settings__hint' },
      [a.phone ? `+${a.phone}` : '', a.username ? `@${a.username}` : '']
        .filter(Boolean).join(' · ')));
}

function bioControl(id, a) {
  const left = el('span', { class: 'settings__unit u-tabular' });
  const input = el('input', {
    class: 'field__input', type: 'text', id, value: a.bio, maxLength: a.bioMax,
    autocomplete: 'off',
    oninput: () => { left.textContent = String(a.bioMax - input.value.length); },
    onchange: () => saveAccount({ key: 'bio', value: input.value.replace(/\n/g, ' ') }),
  });
  left.textContent = String(a.bioMax - a.bio.length);
  return el('label', { class: 'field settings__field settings__field--wide' }, input, left);
}

function usernameControl(id, a, status) {
  let timer = 0;
  let asked = '';
  const input = el('input', {
    class: 'field__input', type: 'text', id, value: a.username, autocomplete: 'off',
    oninput: () => {
      clearTimeout(timer);
      const name = input.value.trim().replace(/^@/, '');
      if (!name || name === a.username) {
        status.textContent = '';
        return;
      }
      // The check — when typing has paused, not on every letter.
      timer = setTimeout(async () => {
        asked = name;
        try {
          const r = await hooks.load('account.checkUsername', { userId: a.id, username: name });
          if (asked === name) status.textContent = USERNAME_HINTS[r.result] ?? '';
        } catch (error) {
          hooks.report(error);
        }
      }, 400);
    },
    onchange: () => {
      const name = input.value.trim().replace(/^@/, '');
      if (name !== a.username) saveAccount({ key: 'username', value: name });
    },
  });
  return el('label', { class: 'field settings__field settings__field--wide' },
    el('span', { class: 'settings__unit' }, '@'), input);
}

function nameControl(id, a, which) {
  const input = el('input', {
    class: 'field__input', type: 'text', id, autocomplete: 'off', maxLength: 64,
    value: which === 'first' ? a.firstName : a.lastName,
    onchange: () => saveAccount({
      key: 'name',
      first: which === 'first' ? input.value : a.firstName,
      last: which === 'last' ? input.value : a.lastName,
    }),
  });
  return el('label', { class: 'field settings__field settings__field--wide' }, input);
}

/** The personal channel: "none" and the channels from getSuitablePersonalChats. */
function personalControl(id, a) {
  const select = el('select', {
    class: 'settings__select', id,
    onchange: () => saveAccount({ key: 'personalChat', value: Number(select.value) }),
  }, el('option', { value: '0' }, 'None'));
  if (a.personalChat) {
    select.append(el('option', { value: String(a.personalChat.id), selected: true },
      a.personalChat.title || String(a.personalChat.id)));
  }
  hooks.load('account.personalChats').then((r) => {
    for (const c of r.chats) {
      if (a.personalChat && c.id === a.personalChat.id) continue;
      select.append(el('option', { value: String(c.id) }, c.title));
    }
  }).catch(hooks.report);
  return select;
}

/** Day and month are required, the year is not (0 in TDLib — "not set"). */
function birthdayControl(id, a) {
  const b = a.birthdate;
  const day = el('select', { class: 'settings__select', id, 'aria-label': 'Day' },
    el('option', { value: '0' }, 'Day'),
    ...Array.from({ length: 31 }, (_, i) => el('option',
      { value: String(i + 1), selected: b?.day === i + 1 }, String(i + 1))));
  const month = el('select', { class: 'settings__select', 'aria-label': 'Month' },
    el('option', { value: '0' }, 'Month'),
    ...MONTHS.map((m, i) => el('option',
      { value: String(i + 1), selected: b?.month === i + 1 }, m)));
  const year = el('input', {
    class: 'field__input settings__number', type: 'number', min: '1900', max: '2100',
    placeholder: 'Year', value: b?.year ? String(b.year) : '', 'aria-label': 'Year',
  });
  const save = () => {
    const d = Number(day.value);
    const m = Number(month.value);
    // A half-filled date is not saved; both empty — remove it.
    if ((d === 0) !== (m === 0)) return;
    saveAccount({ key: 'birthdate', day: d, month: m, year: Number(year.value) || 0 });
  };
  day.addEventListener('change', save);
  month.addEventListener('change', save);
  year.addEventListener('change', save);
  return el('div', { class: 'settings__inline' }, day, month,
    el('label', { class: 'field settings__field' }, year));
}

function renderAccount() {
  if (!account) {
    reloadAccount();
    return [el('p', { class: 'settings__hint' }, 'Loading…')];
  }
  const a = account;
  if (accountView === 'color') return renderColors(a);
  const bio = uid();
  const first = uid();
  const last = uid();
  const username = uid();
  const personal = uid();
  const birthday = uid();
  const status = el('p', { class: 'settings__hint', role: 'status' });
  return [
    accountHeader(a),
    group(null,
      row(bio, 'Bio',
        'Any details such as age, occupation or city. '
        + 'Example: 23 y.o. designer from San Francisco.',
        bioControl(bio, a))),
    group(null,
      row(first, 'First name', null, nameControl(first, a, 'first')),
      row(last, 'Last name', 'Optional.', nameControl(last, a, 'last')),
      row(username, 'Username',
        'People can find you by this username and contact you without '
        + 'knowing your phone number.',
        usernameControl(username, a, status)),
      status,
      row(uid(), 'Phone number', null,
        el('button', {
          class: 'btn settings__link u-tabular', type: 'button',
          // The same as the native client: the number changes only from the phone.
          onclick: () => alertBox('You can change your phone number only in the '
            + 'official Telegram app on your phone.'),
        }, a.phone ? `+${a.phone}` : '—'))),
    group(null,
      row(personal, 'Personal channel',
        'Shown in your profile. Only public channels you own can be picked.',
        personalControl(personal, a)),
      row(uid(), 'Name color',
        'The colors of your profile, your name and replies to your messages.',
        el('button', {
          class: 'btn settings__link', type: 'button',
          onclick: () => { accountView = 'color'; colorTab = 'profile'; pick = null; renderPane(); },
        }, el('span', { class: `color-swatch color-swatch--small swatch-a${a.accentId}` }),
        el('span', { class: `color-swatch color-swatch--small${a.profileAccentId >= 0 ? ` swatch-p${a.profileAccentId}` : ''}` })))),
    group(null,
      row(birthday, 'Birthday',
        'Only your contacts can see it. The year is optional.',
        birthdayControl(birthday, a))),
  ];
}

// ----------------------------------------------------------- sections
// Call devices and volume — the same panel as in the call window
// (calls/devices.js). Kept in this page's browser, not on the server.
async function renderCalls() {
  const relayId = uid();
  return [
    group('Devices and volume', devicePanel()),
    el('p', { class: 'settings__hint' },
      'Saved in this browser: another device running the app keeps its own choice. '
      + 'Changes apply to a call in progress right away.'),
    // The server's call relay (calls/relay.js) — a choice of this window too.
    group('Connection',
      row(relayId, 'Route calls through the server',
        'The fptg server relays call audio and video, so calls work where Telegram itself '
        + 'is blocked. Calls stay end-to-end encrypted. Automatic: when the server is on '
        + 'another computer. Applies to the next call.',
        selectControl(relayId, [
          { value: 'auto', label: 'Automatic' },
          { value: 'on', label: 'Always' },
          { value: 'off', label: 'Never' },
        ], getPref('callRelay'), (value) => setPref('callRelay', value)))),
    ...await renderAcceptCalls(),
  ];
}

/** Chat settings: scale, theme, accent — the window's look; then the account. */
function renderChats() {
  return chatSettingsParts(swatchGrid(ACCENTS, 'app-', currentAccent(), (key) => {
    setAccent(key);
    renderPane();
  }, 'color-grid--inline'));
}

// The Advanced subpages: "Data and storage" and our own.
const ADVANCED_VIEWS = {
  downloads: { label: 'Downloads', render: () => renderDownloads() },
  autodownload: { label: 'Automatic media download', render: () => renderAutoDownload() },
  storage: { label: 'Storage usage', render: () => renderStorage() },
  maps: { label: 'Location service', render: () => renderMaps() },
};

function openAdvanced(view) {
  advancedView = view;
  renderPane();
}

function renderAdvanced() {
  const sub = advancedView && ADVANCED_VIEWS[advancedView];
  if (sub) {
    return [
      el('button', {
        class: 'btn settings__back', type: 'button',
        onclick: () => openAdvanced(null),
      }, icon('chevron-left'), 'Advanced'),
      el('h3', { class: 'settings__subheading' }, sub.label),
      ...sub.render(),
    ];
  }
  const traffic = uid();
  const tray = uid();
  const device = uid();
  const server = uid();
  return [
    group('Data and storage',
      navRow({ iconName: 'download', label: 'Downloads', hint: 'Parallel downloads and speed limit.',
        onClick: () => openAdvanced('downloads') }),
      navRow({ iconName: 'image', label: 'Automatic media download', hint: 'What downloads by itself.',
        onClick: () => openAdvanced('autodownload') }),
      navRow({ iconName: 'archive', label: 'Storage usage', hint: 'Media cache and its limits.',
        onClick: () => openAdvanced('storage') }),
      navRow({ iconName: 'pin', label: 'Location service', hint: 'Where a location from a message opens.',
        onClick: () => openAdvanced('maps') })),
    group('Network',
      navRow({ iconName: 'globe', label: 'Connection type', hint: 'Proxy for the server’s connection to Telegram.',
        onClick: openProxies })),
    group('System integration',
      row(tray, 'Close to tray',
        'The close button hides the window and keeps the app running. '
        + 'Quit from the tray icon.',
        switchControl(tray, data.closeToTray, (checked, input) => commit(
          { key: 'closeToTray', value: checked }, input,
          (node, d) => { node.checked = d.closeToTray; }))),
      // Not the server but this window's look — without commit (ui/status-bar.js).
      row(traffic, 'Show connection traffic',
        'Under Online: what this window has received and sent, '
        + 'with the current speed.',
        switchControl(traffic, trafficShown(), (checked) => setTrafficShown(checked)))),
    group('Server',
      row(device, 'Device name',
        'How this app is listed in Telegram under Active sessions. '
        + 'Takes effect the next time an account signs in.',
        textControl(device, data.deviceModel, (value, input) => commit(
          { key: 'deviceModel', value }, input,
          (node, d) => { node.value = d.deviceModel; }))),
      // Signing in to the server (core/session.js): who and where; signing out
      // ends the session on the server — in the window it is also tray → Sign out.
      row(server, 'fptg server',
        `Signed in as ${currentUser() || '?'} on ${serverBase.replace(/^https?:\/\//, '')}.`,
        el('button', { id: server, class: 'btn settings__link', type: 'button',
          onclick: () => { signOut(); } }, 'Sign out'))),
  ];
}

async function renderNotifications() {
  const n = data.notify;
  const account = await renderNotifyScopes().catch((error) => {
    hooks.report(error);
    return [];
  });
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
    ...account,
    group('Desktop notifications',
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
    group('Notification text',
      row(titleFont, 'Title size',
        `The chat name (${n.fontMin}–${n.fontMax}).`,
        font(titleFont, 'titleFont', n.titleFont)),
      row(textFont, 'Message size',
        `The message preview (${n.fontMin}–${n.fontMax}).`,
        font(textFont, 'textFont', n.textFont))),
  ];
}

/** Where to open location points: the default service or ask. */
function renderMaps() {
  const name = uid();
  const options = [{ id: '', label: 'Ask every time' }, ...MAP_PROVIDERS];
  return [
    el('p', { class: 'settings__intro' },
      'Where a location from a message opens. With “Ask every time” '
      + 'a list of services shows up on each click.'),
    group(null,
      ...options.map((p) => {
        const id = uid();
        const radio = el('input', {
          class: 'settings__check', type: 'radio', name, id,
          checked: (data.mapsProvider ?? '') === p.id,
          onchange: () => commit({ key: 'maps.provider', value: p.id }, radio,
            (node, d) => {
              setMapProvider(d.mapsProvider ?? '');
              node.checked = (d.mapsProvider ?? '') === p.id;
            }),
        });
        return row(id, p.label, null, radio);
      })),
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
 * The "media kind × chat kind" grid. As a table rather than a group of
 * checkboxes for every media kind, as in the native window: the page is
 * wide enough, and a column reads as "what downloads in groups" at a glance.
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

/** Updates only the cache figures — the input fields are not touched. */
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
  // The figures move while the app runs, so they are asked on every visit to
  // the section; fresh ones arrive with the storage event.
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
    ...SECTIONS.map((s) => (s.sep ? el('hr', { class: 'settings__sep' }) : el('button', {
      class: `settings__tab${s.id === current ? ' is-active' : ''}`,
      type: 'button',
      'aria-current': s.id === current ? 'page' : null,
      onclick: () => select(s.id),
    }, icon(s.icon, 'icon--sm'), el('span', {}, s.label)))));
}

/**
 * A section into the panel. An async section (data from TDLib) is first
 * prepared whole, the old content stays in place meanwhile (the panel is
 * "busy"), and only then the swap: the same as window transitions
 * (ui/tgbox.js). A section's first showing — "Loading…" while it prepares.
 */
async function renderPane() {
  const section = PAGES.find((s) => s.id === current) ?? PAGES[0];
  const my = ++paneSeq;
  const sameSection = pane.dataset.section === section.id;
  if (!sameSection) {
    pane.dataset.section = section.id;
    storageView = null;
    clear(pane).append(paneHead(section), paneBody([el('p', { class: 'settings__hint' }, 'Loading…')]));
  }
  if (!data) return;
  pane.classList.add('is-busy');
  let nodes;
  try {
    nodes = await section.render();
  } catch (error) {
    nodes = [el('p', { class: 'settings__error', role: 'alert' }, error?.message || String(error))];
  }
  if (my !== paneSeq) return;
  pane.classList.remove('is-busy');
  const body = pane.querySelector('.settings__body');
  const top = sameSection ? body?.scrollTop ?? 0 : 0;
  clear(pane).append(paneHead(section), paneBody(nodes.filter(Boolean)));
  pane.querySelector('.settings__body').scrollTop = top;
}

function paneHead(section) {
  return el('header', { class: 'settings__head' },
    el('h2', { class: 'settings__heading' }, section.label),
    el('button', {
      class: 'btn btn--icon', type: 'button', title: 'Close',
      onclick: close,
    }, icon('close'), el('span', { class: 'u-sr-only' }, 'Close')));
}

// The content column — in the centre of the panel (blocks/_settings.scss).
function paneBody(nodes) {
  return el('div', { class: 'settings__body' },
    el('div', { class: 'settings__content' }, ...nodes));
}

function select(id) {
  current = id;
  advancedView = null;
  renderNav();
  renderPane();
}

async function open() {
  if (dialog.open) return;
  // The account changes from the phone too — it is asked anew on every open.
  account = null;
  accountView = 'main';
  advancedView = null;
  pick = null;
  delete pane.dataset.section;
  renderNav();
  renderPane();
  dialog.showModal();
  try {
    // Premium decides which settings are active (ui/setkit.js).
    const [settings, me] = await Promise.all([
      hooks.load('settings.get'),
      hooks.load('account.get').catch(() => null),
    ]);
    data = settings;
    if (me) {
      account = me;
      setPremium(me.premium);
    }
    renderPane();
  } catch (error) {
    hooks.report(error);
  }
}

function close() {
  dialog.close();
}

/** Open right on a section (a click on "Online" in the status bar). */
export function openSettings(id) {
  if (dialog.open) {
    select(id);
    return;
  }
  if (PAGES.some((s) => s.id === id)) current = id;
  open();
}

/**
 * While focus is in a field of this page, the section is not rebuilt:
 * otherwise someone else's change (from another tab or the native window)
 * would knock the caret out of the field being typed in.
 */
function editing() {
  const active = document.activeElement;
  return !!active && pane.contains(active) && active.matches('input[type="text"], input[type="number"]');
}

export function mountSettings(node, button, options) {
  dialog = node;
  opener = button;
  hooks = options;
  initKit(options, () => {
    if (dialog.open && !editing()) renderPane();
  });
  nav = el('nav', { class: 'settings__nav', 'aria-label': 'Settings sections' });
  pane = el('div', { class: 'settings__pane' });
  dialog.append(el('div', { class: 'settings__window' }, nav, pane));

  opener.addEventListener('click', open);
  // Esc with the viewer open (the avatar gallery lives inside this dialog)
  // closes only the viewer.
  dialog.addEventListener('cancel', (event) => {
    if (viewerOpen()) event.preventDefault();
  });
  // A click outside the window — on the <dialog> itself, which takes the
  // whole screen around it — closes it, as with any modal layer.
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
