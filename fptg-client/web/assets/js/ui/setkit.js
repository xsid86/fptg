import { el } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { store } from '../core/store.js';

// Shared by the settings sections (ui/settings.js and the sections in
// ui/set*.js): rows, toggles, link rows as in Telegram Desktop, TDLib calls
// through admin (webapi.pas: ADMIN_METHODS / SETTINGS_METHODS — TDLib
// answers as they are, fields per td_api.tl of commit d1085f9) and the
// Premium flag.
//
// A setting available only with Premium is not hidden without it but
// becomes inactive (as in Desktop — with a lock and a Premium mark):
// row/navRow with { premium: true }.

let hooks = { load: () => Promise.reject(new Error('settings are not mounted')), report: () => {} };
let refresher = () => {};
let premium = null;

export function initKit(options, refresh) {
  hooks = options;
  refresher = refresh;
}

export const load = (cmd, args) => hooks.load(cmd, args);
export const report = (error) => hooks.report(error);
/** Redraw the open section (the data changed). */
export const refresh = () => refresher();

/**
 * The latest TDLib updates of these types (td.kept): { type: object | null }.
 * The server returns them as strings, as they came (webapi.pas,
 * CmdTdKept). A type with a colon at the end ("updateQuickReplyShortcut:")
 * — all those kept under "type:id" keys: an array of objects.
 */
export async function kept(types) {
  const raw = (await hooks.load('td.kept', { types })) ?? {};
  const parse = (text) => {
    try {
      return text ? JSON.parse(text) : null;
    } catch {
      return null;
    }
  };
  const out = {};
  for (const t of types) {
    if (t.endsWith(':')) {
      out[t] = Object.keys(raw).filter((k) => k.startsWith(t)).map((k) => parse(raw[k])).filter(Boolean);
    } else {
      out[t] = parse(raw[t]);
    }
  }
  return out;
}

/** TDLib steps in turn -> answers by keys; a soft step does not fail on an error. */
export const td = (steps) => hooks.load('admin', { steps });
export async function one(method, params = {}) {
  return (await td([{ key: 'r', method, params }])).r;
}
/** Is a soft step's answer an error? */
export const failed = (answer) => !answer || answer['@type'] === 'error';

export const myId = () => store.chats.find((c) => c.kind === 'self')?.id ?? 0;
export const me = () => ({ '@type': 'messageSenderUser', user_id: Number(myId()) });

/** The account's Premium: account.get (settings.js) or the Saved Messages row. */
export function setPremium(value) {
  premium = !!value;
}
export function isPremium() {
  return premium ?? !!store.chats.find((c) => c.kind === 'self')?.premium;
}
const locked = (needs) => !!needs && !isPremium();

/** A change -> TDLib; an error — into a notice; then the section anew. */
export async function saving(fn, { redraw = true } = {}) {
  try {
    await fn();
  } catch (error) {
    report(error);
  }
  if (redraw) refresh();
}

let nextId = 0;
export const uid = () => `settings-${++nextId}`;

// ------------------------------------------------------------ controls
function premiumBadge() {
  return el('span', { class: 'settings__badge', title: 'Telegram Premium' }, icon('star', 'icon--xs'), 'Premium');
}

function disableInside(node) {
  for (const c of node.querySelectorAll('input, button, select, textarea')) c.disabled = true;
}

/** A section row: the label and hint on the left, the control on the right. */
export function row(id, label, hint, control, { premium: needs = false } = {}) {
  const lock = locked(needs);
  const box = el('div', { class: 'settings__control' }, control);
  if (lock) disableInside(box);
  return el('div', { class: `settings__row${lock ? ' is-locked' : ''}` },
    el('div', { class: 'settings__text' },
      el('label', { class: 'settings__label', htmlFor: id },
        label, needs ? premiumBadge() : null),
      hint ? el('p', { class: 'settings__hint' }, hint) : null),
    box);
}

export function group(title, ...rows) {
  return el('section', { class: 'settings__group' },
    title ? el('h3', { class: 'settings__group-title' }, title) : null,
    ...rows);
}

export function intro(text) {
  return el('p', { class: 'settings__intro' }, text);
}

export function switchControl(id, checked, onCommit) {
  const input = el('input', {
    class: 'switch__input', type: 'checkbox', id, checked,
    onchange: () => onCommit(input.checked, input),
  });
  return el('span', { class: 'switch' }, input, el('span', { class: 'switch__track' }));
}

/** A toggle as a whole row: row + switchControl. */
export function switchRow(label, hint, checked, onCommit, options = {}) {
  const id = uid();
  return row(id, label, hint, switchControl(id, checked, onCommit), options);
}

/**
 * A number with a unit. Sent on change (Enter or leaving the field), not on
 * every input: otherwise typing "100" would first save 1.
 */
export function numberControl(id, { value, min, max, unit }, onCommit) {
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

export function textControl(id, value, onCommit) {
  const input = el('input', {
    class: 'field__input', type: 'text', id, value, autocomplete: 'off',
    onchange: () => onCommit(input.value.trim(), input),
  });
  return el('label', { class: 'field settings__field settings__field--wide' }, input);
}

/** A drop-down list: options — [{ value, label }]. */
export function selectControl(id, options, value, onCommit) {
  const select = el('select', {
    class: 'settings__select', id,
    onchange: () => {
      const o = options.find((x) => String(x.value) === select.value);
      if (o) onCommit(o.value, select);
    },
  }, ...options.map((o) => el('option', { value: String(o.value), selected: o.value === value }, o.label)));
  return select;
}

/** Radio buttons as rows: options — [{ value, label, hint, premium }]. */
export function radioRows(options, value, onCommit) {
  const name = uid();
  return options.map((o) => {
    const id = uid();
    const radio = el('input', {
      class: 'settings__check', type: 'radio', name, id,
      checked: o.value === value,
      onchange: () => onCommit(o.value),
    });
    return row(id, o.label, o.hint ?? null, radio, { premium: o.premium });
  });
}

/**
 * A link row, as in Desktop: a label (with a hint), on the right — the
 * current value in the accent colour and a chevron; a click — a window or a subpage.
 */
export function navRow({ label, value = '', hint = '', iconName = '', onClick, premium: needs = false, danger = false }) {
  const lock = locked(needs);
  return el('button', {
    class: `settings__row settings__nav-row${danger ? ' is-danger' : ''}${lock ? ' is-locked' : ''}`,
    type: 'button', disabled: lock || !onClick,
    onclick: onClick,
  },
  iconName ? icon(iconName, 'settings__nav-icon') : null,
  el('span', { class: 'settings__text' },
    el('span', { class: 'settings__label' }, label, needs ? premiumBadge() : null),
    hint ? el('span', { class: 'settings__hint' }, hint) : null),
  el('span', { class: 'settings__nav-value' }, String(value ?? '')),
  danger ? null : icon('chevron-right', 'settings__chevron'));
}

/** An action button in a row (Terminate, Unblock…). */
export function actionButton(label, onClick, { danger = false, primary = false } = {}) {
  return el('button', {
    class: `btn${primary ? ' btn--primary' : ''} settings__action${danger ? ' is-danger' : ''}`,
    type: 'button', onclick: onClick,
  }, label);
}

export function loading() {
  return [el('p', { class: 'settings__hint' }, 'Loading…')];
}

// --------------------------------------------------------------- time
const DAY = 86400;

/** "1 day", "2 weeks", "1 month"… for auto-delete timers. */
export function periodLabel(seconds) {
  if (!seconds) return 'Off';
  const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
  if (seconds % (365 * DAY) === 0) return plural(seconds / (365 * DAY), 'year');
  if (seconds % (31 * DAY) === 0) return plural(seconds / (31 * DAY), 'month');
  if (seconds % (30 * DAY) === 0) return plural(seconds / (30 * DAY), 'month');
  if (seconds % (7 * DAY) === 0) return plural(seconds / (7 * DAY), 'week');
  if (seconds % DAY === 0) return plural(seconds / DAY, 'day');
  if (seconds % 3600 === 0) return plural(seconds / 3600, 'hour');
  return plural(Math.round(seconds / 60), 'minute');
}

/** The date and time in English: "Oct 17, 2026 at 14:05". */
export function dateTime(unix) {
  if (!unix) return '';
  const d = new Date(unix * 1000);
  return `${d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })} at ${
    d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}`;
}
