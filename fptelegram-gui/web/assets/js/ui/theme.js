import { clear } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { openMenu } from '../util/menu.js';
import { postShell } from './shell.js';

// Theme switching: the brush in the status bar opens a list of five.
//
// The whole palette hangs off ATTRIBUTES on <html> - never an inline
// style, and never a per-element repaint from here:
//   data-theme  dark | light - the scheme; every token, palette and
//               accent in scss/base hangs off it, for all four themes;
//   data-style  "plain" for the simple themes (scss/themes/_plain),
//               "aurora" for Aurora (scss/themes/_aurora), else absent.
// No stored choice at all is a meaningful state: no attributes, which is
// what leaves the OS preference in charge (a coloured theme then).
//
// The stored value is one of THEMES' ids. index.html, check.html and
// callcard.html apply it before the first paint with the same split;
// this module owns the button, the menu and the changes made through it.

const KEY = 'theme';
const media = window.matchMedia('(prefers-color-scheme: dark)');

// Порядок — как в меню. id — то, что лежит в localStorage; у прежних
// версий там были только 'dark' и 'light', они и остались цветными.
const THEMES = [
  { id: 'dark', label: 'Dark colored' },
  { id: 'light', label: 'Light colored' },
  { id: 'dark-plain', label: 'Dark' },
  { id: 'light-plain', label: 'Light' },
  // Как макет окна на сайте проекта (website/, sections/_mockup.scss):
  // стекло на синей «авроре». Только тёмная — scss/themes/_aurora.
  { id: 'dark-aurora', label: 'Aurora' },
];

let button = null;

// ------------------------------------------------------------- accent
// Акцент приложения (Settings → General). Ключи — те же, что в
// $app-accents (abstracts/_variables.scss): палитра конечна, цвет живёт
// в CSS, а здесь только атрибут <html data-accent>. Синий — по
// умолчанию: без атрибута действует акцент темы. Хранится локально, как
// тема: вид этого окна, а не сервера.
const ACCENT_KEY = 'accent';
export const ACCENTS = ['blue', 'cyan', 'teal', 'green', 'lime', 'amber',
  'orange', 'red', 'pink', 'purple', 'indigo', 'grey'];
const DEFAULT_ACCENT = 'blue';

export function currentAccent() {
  try {
    const v = localStorage.getItem(ACCENT_KEY);
    return ACCENTS.includes(v) ? v : DEFAULT_ACCENT;
  } catch {
    return DEFAULT_ACCENT;
  }
}

export function setAccent(key) {
  if (!ACCENTS.includes(key)) return;
  const root = document.documentElement;
  if (key === DEFAULT_ACCENT) delete root.dataset.accent;
  else root.dataset.accent = key;
  try {
    if (key === DEFAULT_ACCENT) localStorage.removeItem(ACCENT_KEY);
    else localStorage.setItem(ACCENT_KEY, key);
  } catch {
    // Не запомнится до следующего запуска, но сейчас подействует.
  }
  // В Aurora из акцента выведен и фон — рамка окна тоже за ним.
  paintFrame(schemeOf(effective()));
}

function stored() {
  try {
    const v = localStorage.getItem(KEY);
    return THEMES.some((t) => t.id === v) ? v : null;
  } catch {
    // Private windows and blocked site data both throw here. Not an
    // error: it only means the choice cannot outlive the session.
    return null;
  }
}

/** What is on screen right now, explicit choice or OS preference. */
function effective() {
  return stored() ?? (media.matches ? 'dark' : 'light');
}

const schemeOf = (id) => (id.startsWith('dark') ? 'dark' : 'light');
// Стиль поверх схемы — то, что после дефиса: plain | aurora.
const styleOf = (id) => id.split('-')[1] ?? null;

// Цвет токена темы как '#rrggbb' (style трогать нельзя, а
// getComputedStyle отдаёт токен так, как он записан). Через пиксель
// канвы, а не её fillStyle: color-mix (токены Aurora) fillStyle отдаёт
// как 'color(srgb …)', а winframe ждёт '#rrggbb'.
let probe = null;
function tokenColor(name) {
  probe ??= Object.assign(document.createElement('canvas'), { width: 1, height: 1 })
    .getContext('2d', { willReadFrequently: true });
  const css = getComputedStyle(document.documentElement);
  // Полупрозрачный токен (кайма Aurora — акцент на 14%) — поверх фона
  // страницы, как его и видно; иначе пиксель отдал бы чистый акцент.
  probe.fillStyle = '#000000';
  probe.fillStyle = css.getPropertyValue('--c-bg').trim();
  probe.fillRect(0, 0, 1, 1);
  probe.fillStyle = '#000000';
  probe.fillStyle = css.getPropertyValue(name).trim();
  probe.fillRect(0, 0, 1, 1);
  const [r, g, b] = probe.getImageData(0, 0, 1, 1).data;
  return `#${[r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('')}`;
}

// Рамка окна в цвет темы (winframe.pas): заголовок — фон страницы,
// текст и кайма — свои токены. В обычном браузере postShell молчит.
function paintFrame(scheme) {
  postShell({
    t: 'frame',
    caption: tokenColor('--c-bg'),
    text: tokenColor('--c-text'),
    border: tokenColor('--c-border'),
    dark: scheme === 'dark',
  });
}

function render() {
  const now = effective();
  // The RESOLVED scheme, mirrored onto <body> so stylesheets have
  // something that is always there to match on - data-theme on <html>
  // is the choice, and is absent while the OS is deciding. index.html
  // sets this before the first paint; this keeps it true afterwards.
  document.body.dataset.scheme = schemeOf(now);
  paintFrame(schemeOf(now));
  if (!button) return;
  clear(button).append(icon('brush', 'icon--sm'));
  button.title = `Theme: ${THEMES.find((t) => t.id === now)?.label ?? now}`;
  button.setAttribute('aria-label', button.title);
}

function apply(id) {
  const root = document.documentElement;
  root.dataset.theme = schemeOf(id);
  const style = styleOf(id);
  if (style) root.dataset.style = style;
  else delete root.dataset.style;
  try {
    localStorage.setItem(KEY, id);
  } catch {
    // Same as above: the theme still applies, it just will not be
    // remembered next time.
  }
  render();
}

function openThemes() {
  const now = effective();
  openMenu(button, THEMES.map((t) => ({
    label: t.label,
    checked: t.id === now,
    onSelect: () => apply(t.id),
  })));
}

export function mountThemeToggle(node) {
  button = node;
  button.addEventListener('click', openThemes);
  // Follow the OS while no explicit choice has been made, so the window
  // changes with everything else on the desktop rather than sitting
  // stubbornly on whatever it started as.
  media.addEventListener('change', () => { if (!stored()) render(); });
  render();
}
