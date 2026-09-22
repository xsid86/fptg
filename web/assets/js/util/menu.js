import { el } from '../core/dom.js';

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
// THE ELEMENT IS BUILT FRESH EVERY TIME, and that is not laziness about
// reuse - it is required. The browser remembers which `position-try`
// option last worked FOR A GIVEN ELEMENT (so a menu cannot oscillate
// between two placements), and a reused node carries that memory into
// its next opening: measured here, a menu that had legitimately flipped
// above a chip near the bottom of the list then kept flipping for a chip
// with 300px of clear space under it. A new node starts with no such
// history.

let menu = null;
let anchorEl = null;

function releaseAnchor() {
  if (anchorEl) anchorEl.classList.remove('is-menu-anchor');
  anchorEl = null;
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
 */
export function openMenu(anchor, items) {
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

  for (const item of items) {
    if (item === '-') {
      node.append(el('hr', { class: 'menu__sep' }));
      continue;
    }
    node.append(el('button', {
      class: `menu__item${item.checked ? ' is-checked' : ''}`,
      type: 'button',
      role: 'menuitem',
      disabled: item.disabled === true,
      onclick: () => {
        closeMenu();
        item.onSelect?.();
      },
    },
    el('span', { class: 'menu__mark', 'aria-hidden': 'true' }),
    el('span', { class: 'menu__label', textContent: item.label })));
  }

  document.body.append(node);
  menu = node;
  anchorEl = anchor;
  anchor.classList.add('is-menu-anchor');
  node.showPopover();
}
