import { el } from '../core/dom.js';
import { markPopDirection } from './pop.js';

// A popup menu. One is open at a time, which is also what lets the CSS
// pin it to its anchor without a single coordinate being written from
// here.
//
// TWO PLATFORM FEATURES DO THE WORK, and it is worth knowing which does
// what, because they have different support:
//
//   popover        - puts the menu in the top layer (so it is never
//                    clipped by the scrolling chat list), and brings
//                    light dismiss and Escape with it for free.
//                    Everywhere since Chrome 114 / Firefox 125 /
//                    Safari 17, i.e. broader than `field-sizing`, which
//                    this app already relies on.
//   anchor posit.  - pins it under the chip that opened it. Chromium
//                    only. Where it is missing the UA's own popover
//                    styling centres the menu in the viewport, which is
//                    still a usable menu - so this degrades rather than
//                    breaks, and the stylesheet guards it with @supports.
//
// Position is a CLASS on the anchor (`is-menu-anchor`), never an inline
// style: the app's standing rule is that JavaScript changes appearance
// by adding and removing classes, and a menu is not an excuse to break
// it. See core/dom.js.
//
// OPENING AT THE POINTER is the one thing that class cannot express - a
// cursor position is not one of a finite set the way a colour or a
// width is. It is still not written as an inline style. A one-rule
// ADOPTED STYLESHEET carries the two numbers as custom properties, and
// a zero-sized marker element reads them:
//
//   * nothing gains a `style` attribute, so nothing becomes
//     unoverridable and the cascade still decides everything;
//   * the marker is a perfectly ordinary anchor, so the placement, the
//     edge flipping and the @supports fallback below are the SAME
//     machinery as for a menu hung off a button - no second way of
//     positioning a menu to keep working.
//
// The menu also remembers what it is ABOUT (originEl) separately from
// what it is positioned against (anchorEl). With the pointer marker the
// two are different, and the questions "has this message been rebuilt"
// and "where does this menu sit" stop being the same question.
//
// THE ELEMENT IS BUILT FRESH EVERY TIME, and that is not laziness about
// reuse - it is required. The browser remembers which `position-try`
// option last worked FOR A GIVEN ELEMENT (so a menu cannot oscillate
// between two placements), and a reused node carries that memory into
// its next opening: measured here, a menu that had legitimately flipped
// above a chip near the bottom of the list then kept flipping for a chip
// with 300px of clear space under it. A new node starts with no such
// history.

let menu = null;
let anchorEl = null;   // what the menu is POSITIONED against
let originEl = null;   // what the menu is ABOUT
let point = null;      // the zero-sized marker, made once
let sheet = null;      // the one rule that carries the pointer position

function releaseAnchor() {
  if (anchorEl) anchorEl.classList.remove('is-menu-anchor');
  anchorEl = null;
  originEl = null;
  point?.remove();
}

/**
 * Puts the marker where the pointer was.
 *
 * The rule is rewritten rather than appended to: one stylesheet, one
 * declaration, for the life of the page.
 */
function placePoint(at) {
  if (!point) point = el('div', { class: 'menu-point' });
  if (!sheet) {
    sheet = new CSSStyleSheet();
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  }
  sheet.replaceSync(
    `:root{--menu-x:${Math.round(at.x)}px;--menu-y:${Math.round(at.y)}px}`);
  document.body.append(point);
  return point;
}

/**
 * Moves an open menu's anchor onto the node that has replaced it.
 *
 * Needed because the history REBUILDS a message's element whenever its
 * payload changes - a reaction, a download tick, a read receipt - and
 * the anchor is that element. Losing it does not close the menu: the
 * popover stays open with `position-anchor` pointing at nothing, so it
 * drops out of the corner of the screen, which reads as "the menu
 * disappeared on its own". Measured, not guessed: after one update the
 * old node was detached and no element in the document carried
 * is-menu-anchor any more.
 *
 * Called from the replacement itself (ui/history.js), so no ordering
 * between subscribers has to be got right.
 */
export function reanchorMenu(from, to) {
  if (!menu || !from || !to || originEl !== from) return;
  originEl = to;
  // Only when the menu is positioned against that very node. Opened at
  // the pointer it hangs off the marker instead, and the marker does
  // not move because a message was redrawn.
  if (anchorEl === from) {
    from.classList.remove('is-menu-anchor');
    anchorEl = to;
    to.classList.add('is-menu-anchor');
  }
}

/**
 * Closes an open menu whose anchor has left the document for good.
 *
 * The counterpart to reanchorMenu: a REPLACED message hands its anchor
 * over, a DELETED one has nothing to hand over, and a menu acting on a
 * message that is no longer there should not still be on screen. Left
 * alone it would not close either - it would sit in the corner with
 * nothing to anchor to.
 */
export function closeMenuIfDetached() {
  if (menu && originEl && !originEl.isConnected) closeMenu();
}

export function closeMenu() {
  const node = menu;
  menu = null;
  releaseAnchor();
  if (!node) return;
  // hidePopover() throws when the popover is not showing, which is the
  // common case here (closing something already light-dismissed).
  try { node.hidePopover(); } catch { /* already closed */ }
  node.remove();
}

/**
 * items: { label, checked, disabled, onSelect } or the string '-' for a
 * separator. Selecting an item closes the menu first, so a handler is
 * free to open a prompt or another menu.
 *
 * options.header is a node put above the items, inside the same
 * popover - what the message menu hangs its row of reactions from. It
 * is the caller's node and the caller's business; this function only
 * finds it a place to sit.
 *
 * options.at is a viewport point - {x, y} off a pointer event - and
 * opens the menu there instead of against `anchor`. `anchor` still says
 * what the menu is about, which is what decides when it has to close.
 */
export function openMenu(anchor, items, options = {}) {
  closeMenu();

  const node = el('div', { class: 'menu', popover: 'auto', role: 'menu' });
  // Light dismiss and Escape close the popover without going through
  // closeMenu(), so the node has to clean up after itself. The event is
  // delivered asynchronously, which is why this checks whether it is
  // still the current menu: by the time a closing node's toggle arrives,
  // a newer menu may already be open, and blindly clearing the module
  // state here would strip the new one of its anchor.
  node.addEventListener('toggle', (event) => {
    if (event.newState !== 'closed') return;
    node.remove();
    if (menu === node) {
      menu = null;
      releaseAnchor();
    }
  });

  if (options.header) node.append(options.header);

  for (const item of items) {
    if (item === '-') {
      node.append(el('hr', { class: 'menu__sep' }));
      continue;
    }
    node.append(el('button', {
      class: `menu__item${item.checked ? ' is-checked' : ''}${item.className ? ` ${item.className}` : ''}`,
      type: 'button',
      role: 'menuitem',
      disabled: item.disabled === true,
      onclick: () => {
        closeMenu();
        item.onSelect?.();
      },
    },
    el('span', { class: 'menu__mark', 'aria-hidden': 'true' }),
    // item.node — своё содержимое вместо подписи (строка аккаунта с
    // аватаркой в переключателе, ui/status-bar.js).
    item.node ?? el('span', { class: 'menu__label', textContent: item.label })));
  }

  document.body.append(node);
  menu = node;
  originEl = anchor;
  anchorEl = options.at ? placePoint(options.at) : anchor;
  anchorEl.classList.add('is-menu-anchor');
  node.showPopover();
  markPopDirection(node, anchorEl);
}
