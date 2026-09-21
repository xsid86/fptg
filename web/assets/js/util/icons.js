import { el } from '../core/dom.js';

// The sprite is fetched once and injected into the document.
//
// Why not just <use href="assets/img/icons.svg#i-pin">? Because an
// external reference is fetched per <use> in some engines and, more to
// the point, cannot be styled from this document - currentColor stops
// working, and currentColor is the entire reason the icons carry no
// colour of their own. Injected once, every <use> resolves locally.
//
// The sheet is a grid, not a stack of <symbol>s, so that it can be
// edited in a vector editor - see the note at the top of icons.svg.
// That means a cell is not at the origin, so a host <svg> cannot just
// show "0 0 24 24"; it needs a viewBox that is a window onto that one
// cell. Those origins are read off the sheet itself at load time rather
// than written out here a second time: the file is the single source of
// truth, and an icon the user drags in Inkscape keeps working.

const SPRITE_URL = 'assets/img/icons.svg';
const FALLBACK_BOX = '0 0 24 24';

/** icon name -> the "x y w h" window onto its cell, filled by loadIcons. */
const CELLS = new Map();

const attr = (node, name, fallback = 0) => {
  const raw = Number(node.getAttribute(name));
  return Number.isFinite(raw) ? raw : fallback;
};

const round = (v) => Math.round(v * 1000) / 1000;

/**
 * A cell's box in sheet coordinates.
 *
 * Read through the group's transform on purpose. Inkscape stores a move
 * one of two ways depending on its "store transformation" preference:
 * as a transform on the group (rect coordinates stay local) or baked
 * into the children (rect coordinates become absolute, group transform
 * gone). Both land here correctly. Rotation and skew would not, but an
 * icon sheet has neither.
 */
function cellBox(group, rect) {
  const x = attr(rect, 'x');
  const y = attr(rect, 'y');
  const w = attr(rect, 'width', 24);
  const h = attr(rect, 'height', 24);
  const m = group.transform?.baseVal?.consolidate()?.matrix;
  if (!m) return [x, y, w, h];
  return [m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f, w * m.a, h * m.d];
}

/**
 * Forces one element's paint onto currentColor, so it follows the colour of
 * whatever it sits in (hover, a chat accent, a tinted header).
 *
 * Needed because no vector editor can write `currentColor`: Inkscape saves
 * whatever swatch the glyph was drawn with, usually as `style="fill:#..."`.
 * That is worse than a plain attribute - an inline style outranks any
 * stylesheet rule, so it cannot be overridden from CSS either. Hence: drop
 * the declaration from the style, then set the presentation attribute, which
 * only means anything once the inline one is gone.
 *
 * The consequence is that icons here are monochrome by construction. A
 * deliberately two-tone glyph would be flattened; nothing in this UI is.
 */
function normalizePaint(node) {
  for (const prop of ['fill', 'stroke']) {
    const inline = node.style.getPropertyValue(prop);
    const value = inline || node.getAttribute(prop);
    if (!value || value === 'none' || value === 'currentColor') continue;
    if (inline) node.style.removeProperty(prop);
    node.setAttribute(prop, 'currentColor');
  }
}

export async function loadIcons() {
  const response = await fetch(SPRITE_URL);
  if (!response.ok) throw new Error(`icon sprite: ${response.status}`);
  const markup = await response.text();

  // The one place this codebase parses markup, on a file we ship
  // ourselves - never on anything that arrived from the network as
  // data. See the note in core/dom.js.
  const holder = el('div', { hidden: true });
  holder.innerHTML = markup;

  for (const group of holder.querySelectorAll('g[id^="i-"]')) {
    const rect = group.querySelector('[data-cell]');
    if (!rect) continue;
    CELLS.set(group.id.slice(2), cellBox(group, rect).map(round).join(' '));
  }

  // Strip the editing guides. This has to happen before anything
  // references a cell: <use> clones the group as it stands at that
  // moment, and a document rule cannot reach inside the clone to hide
  // them afterwards.
  for (const label of holder.querySelectorAll('[data-guide]')) label.remove();
  for (const rect of holder.querySelectorAll('[data-cell]')) rect.setAttribute('stroke', 'none');

  // Then put every glyph on currentColor, so an icon dropped in from an icon
  // set keeps the colour its editor gave it in the sheet, and still follows
  // the page here. Cells are skipped: their stroke was just cleared above.
  for (const group of holder.querySelectorAll('g[id^="i-"]')) {
    normalizePaint(group);
    for (const node of group.querySelectorAll('*')) {
      if (node.hasAttribute('data-cell')) continue;
      normalizePaint(node);
    }
  }

  document.body.prepend(holder);
}

/** icon('pin') -> <svg class="icon" viewBox="<pin's cell>"><use href="#i-pin"></use></svg> */
export function icon(name, extraClass = '') {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', `icon${extraClass ? ' ' + extraClass : ''}`);
  svg.setAttribute('viewBox', CELLS.get(name) ?? FALLBACK_BOX);
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
 * <use> written into index.html would point at a group that does not
 * exist yet, and whether it re-resolves once the group appears is not
 * something to rely on across engines.
 */
export function hydrateIcons(scope = document) {
  for (const holder of scope.querySelectorAll('[data-icon]')) {
    const svg = icon(holder.dataset.icon, holder.className.replace('icon', '').trim());
    holder.replaceWith(svg);
  }
}
