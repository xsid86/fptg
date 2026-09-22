import { clear } from '../core/dom.js';
import { icon } from '../util/icons.js';

// Light / dark switching.
//
// The whole palette hangs off [data-theme] in scss/base/_root.scss, so
// switching is one ATTRIBUTE on <html> - never an inline style, and
// never a per-element repaint from here. No attribute at all is a
// meaningful third state: it means "no choice made", which is what
// leaves the OS preference in charge.
//
// index.html applies the stored choice before the first paint; this
// module only owns the button and the changes made through it.

const KEY = 'theme';
const media = window.matchMedia('(prefers-color-scheme: dark)');

let button = null;

function stored() {
  try {
    const v = localStorage.getItem(KEY);
    return v === 'dark' || v === 'light' ? v : null;
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

function render() {
  if (!button) return;
  const now = effective();
  const next = now === 'dark' ? 'light' : 'dark';
  // The icon shows what the click WILL DO, not what is on - the same
  // rule the chat list follows for archive and pin, where the state is
  // already visible and the action is not.
  clear(button).append(icon(next === 'dark' ? 'moon' : 'sun', 'icon--sm'));
  button.title = next === 'dark' ? 'Switch to the dark theme'
                                 : 'Switch to the light theme';
  button.setAttribute('aria-label', button.title);
}

function apply(theme) {
  document.documentElement.dataset.theme = theme;
  try {
    localStorage.setItem(KEY, theme);
  } catch {
    // Same as above: the theme still applies, it just will not be
    // remembered next time.
  }
  render();
}

export function mountThemeToggle(node) {
  button = node;
  button.addEventListener('click', () => apply(effective() === 'dark' ? 'light' : 'dark'));
  // Follow the OS while no explicit choice has been made, so the window
  // changes with everything else on the desktop rather than sitting
  // stubbornly on whatever it started as.
  media.addEventListener('change', () => { if (!stored()) render(); });
  render();
}
