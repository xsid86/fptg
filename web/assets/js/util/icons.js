import { el } from '../core/dom.js';

// The sprite is fetched once and injected into the document.
//
// Why not just <use href="assets/img/icons.svg#i-pin">? Because an
// external reference is fetched per <use> in some engines and, more to
// the point, cannot be styled from this document - currentColor stops
// working, and currentColor is the entire reason the icons have no fill
// of their own. Injected once, every <use> resolves locally.

const SPRITE_URL = 'assets/img/icons.svg';

export async function loadIcons() {
  const response = await fetch(SPRITE_URL);
  if (!response.ok) throw new Error(`icon sprite: ${response.status}`);
  const markup = await response.text();

  // The one place this codebase parses markup, on a file we ship
  // ourselves - never on anything that arrived from the network as
  // data. See the note in core/dom.js.
  const holder = el('div', { hidden: true });
  holder.innerHTML = markup;
  document.body.prepend(holder);
}

/** icon('pin') -> <svg class="icon"><use href="#i-pin"></use></svg> */
export function icon(name, extraClass = '') {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', `icon${extraClass ? ' ' + extraClass : ''}`);
  svg.setAttribute('aria-hidden', 'true');
  const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  use.setAttribute('href', `#i-${name}`);
  svg.append(use);
  return svg;
}

const KIND_ICON = {
  channel: 'channel',
  group: 'group',
  bot: 'bot',
  private: 'person',
  secret: 'lock',
  self: 'bookmark',
};

export const kindIcon = (kind) => KIND_ICON[kind] ?? 'chat';

/**
 * Swaps every <span data-icon="name"> placeholder in static markup for a
 * real <use> node. Needed because the sprite arrives asynchronously: a
 * <use> written into index.html would point at a symbol that does not
 * exist yet, and whether it re-resolves once the symbol appears is not
 * something to rely on across engines.
 */
export function hydrateIcons(scope = document) {
  for (const holder of scope.querySelectorAll('[data-icon]')) {
    const svg = icon(holder.dataset.icon, holder.className.replace('icon', '').trim());
    holder.replaceWith(svg);
  }
}
