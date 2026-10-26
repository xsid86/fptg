import { clear } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { openMenu } from '../util/menu.js';
import { postShell } from './shell.js';

// Theme switching: the brush in the status bar opens a list of five.
//
// The whole palette hangs off ATTRIBUTES on <html> - never an inline
// style, and never a per-element repaint from here:
//   data-theme  dark | light - the scheme; every token, palette and
//               accent in scss/base hangs off it, for all five themes;
//   data-style  "plain" for the simple themes (scss/themes/_plain),
//               "aurora" for Aurora (scss/themes/_aurora), else absent.
// No stored choice (first start, or blocked storage) means Aurora -
// DEFAULT_THEME; the OS light/dark preference is not consulted.
//
// The stored value is one of THEMES' ids. index.html, check.html and
// callcard.html apply it before the first paint with the same split;
// this module owns the button, the menu and the changes made through it.

const KEY = 'theme';

// The order — as in the menu. id — what lies in localStorage; earlier
// versions had only 'dark' and 'light' there, and they stayed the colour ones.
const THEMES = [
  // Like the window mockup on the project site (website/, sections/_mockup.scss):
  // glass on an "aurora" of the accent colour. Dark only — scss/themes/_aurora.
  { id: 'dark-aurora', label: 'Aurora' },
  { id: 'dark-plain', label: 'Dark' },
  { id: 'dark', label: 'Dark colored' },
  { id: 'light-plain', label: 'Light' },
  { id: 'light', label: 'Light colored' },
];

// Without a saved choice — Aurora. The same value is in the early scripts of
// index.html, check.html, callcard.html.
const DEFAULT_THEME = 'dark-aurora';

let button = null;

// ------------------------------------------------------------- accent
// The app accent (Settings → General). The keys are the same as in
// $app-accents (abstracts/_variables.scss): the palette is finite, the
// colour lives in CSS, and here only the <html data-accent> attribute. Blue
// is the default: without the attribute the theme's accent applies. Kept
// locally, like the theme: the look of this window, not of the server.
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
    // It will not be remembered until the next run, but it applies now.
  }
  // In Aurora the background is derived from the accent too — the window frame follows it.
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

/** What is on screen right now: the stored choice or the default. */
function effective() {
  return stored() ?? DEFAULT_THEME;
}

const schemeOf = (id) => (id.startsWith('dark') ? 'dark' : 'light');
// The style on top of the scheme — what follows the hyphen: plain | aurora.
const styleOf = (id) => id.split('-')[1] ?? null;

// A theme token's colour as '#rrggbb' (style must not be touched, and
// getComputedStyle returns the token as it is written). Through a canvas
// pixel, not its fillStyle: fillStyle returns color-mix (the Aurora tokens)
// as 'color(srgb …)', while winframe expects '#rrggbb'.
let probe = null;
function tokenColor(name) {
  probe ??= Object.assign(document.createElement('canvas'), { width: 1, height: 1 })
    .getContext('2d', { willReadFrequently: true });
  const css = getComputedStyle(document.documentElement);
    // A semi-transparent token (the Aurora edging — the accent at 14%) — over
    // the page background, as it is seen; otherwise the pixel would give the pure accent.
  probe.fillStyle = '#000000';
  probe.fillStyle = css.getPropertyValue('--c-bg').trim();
  probe.fillRect(0, 0, 1, 1);
  probe.fillStyle = '#000000';
  probe.fillStyle = css.getPropertyValue(name).trim();
  probe.fillRect(0, 0, 1, 1);
  const [r, g, b] = probe.getImageData(0, 0, 1, 1).data;
  return `#${[r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('')}`;
}

// The window frame in the theme colour (winframe.pas): the caption — the
// page background, the text and edging — their own tokens. The desktop
// cards of new messages (desknotify.pas) take the theme too: the card is
// the surface, its text the dim text. In an ordinary browser postShell is
// silent.
function paintFrame(scheme) {
  postShell({
    t: 'frame',
    caption: tokenColor('--c-bg'),
    text: tokenColor('--c-text'),
    border: tokenColor('--c-border'),
    card: tokenColor('--c-surface'),
    dim: tokenColor('--c-text-dim'),
    dark: scheme === 'dark',
  });
}

function render() {
  const now = effective();
  // The RESOLVED scheme, mirrored onto <body> so stylesheets have
  // something that is always there to match on. index.html sets this
  // before the first paint; this keeps it true afterwards.
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

// For "Chat settings" → Theme (ui/setchats.js): the same list and the same
// choice as in the brush menu.
export const themeList = () => THEMES.map((t) => ({ ...t }));
export const currentTheme = () => effective();
export const setTheme = (id) => apply(id);

export function mountThemeToggle(node) {
  button = node;
  button.addEventListener('click', openThemes);
  render();
}
