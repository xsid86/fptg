/**
 * Moving a strip sideways: by dragging it, and by the wheel.
 *
 * For the strips that are wider than the box they sit in and have no
 * scrollbar to grab - the bar is hidden on purpose in both places that
 * use this, because a visible one across a panel or a menu reads as
 * damage.
 *
 * Shared by the emoji panel's set strip and the reaction row above the
 * message menu. The two are the same strip, and the hard-won detail in
 * the drag below is not worth writing twice.
 */
export function sideScroll(strip) {
  dragging(strip);
  wheeling(strip);
}

/**
 * The wheel, turned sideways.
 *
 * A mouse has one wheel and it reports deltaY; over a strip that only
 * moves horizontally that would otherwise do nothing at all, or scroll
 * whatever is behind it. A trackpad's sideways swipe arrives as deltaX,
 * so whichever axis the gesture actually used is the one taken.
 *
 * The event is only swallowed while there IS something to scroll -
 * otherwise a wheel over a short strip would quietly eat the gesture
 * instead of letting it reach the panel underneath.
 */
function wheeling(strip) {
  strip.addEventListener('wheel', (event) => {
    if (strip.scrollWidth <= strip.clientWidth) return;
    // deltaMode says what the numbers are counted in: 0 pixels, 1
    // lines, 2 pages. Chromium sends pixels for a wheel, but a line
    // delta of 3 moved nowhere would look like a dead strip.
    const step = event.deltaMode === 1 ? 16
      : event.deltaMode === 2 ? strip.clientWidth : 1;
    const by = Math.abs(event.deltaX) > Math.abs(event.deltaY)
      ? event.deltaX : event.deltaY;
    if (!by) return;
    strip.scrollLeft += by * step;
    event.preventDefault();
  }, { passive: false });   // or preventDefault is refused
}

function dragging(strip) {
  let from = 0;
  let at = 0;
  let held = false;
  let moved = false;

  strip.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) return;
    from = event.clientX;
    at = strip.scrollLeft;
    held = true;
    moved = false;
    // NOT captured here. Pointer capture redirects the CLICK as well
    // as the pointer events: measured on a real click, the sequence
    // was pointerdown, pointerup with capture held, and then a click
    // whose target was the strip rather than the button under the
    // finger - so every button in the strip stopped working while the
    // drag itself looked fine. A synthetic click misses this entirely,
    // because it never goes through the pointer path at all.
  });

  strip.addEventListener('pointermove', (event) => {
    if (!held) return;
    const by = event.clientX - from;
    // A few pixels of slack, so a click with an unsteady hand is still
    // a click.
    if (!moved && Math.abs(by) > 4) {
      moved = true;
      // Only NOW, when this is certainly a drag and not a click: the
      // pointer keeps reporting here once it has left the strip, so a
      // drag that runs off the edge still works. Best effort - a
      // refused capture must not stop the drag, which is why `held`
      // and not capture is what says one is in progress.
      try { strip.setPointerCapture(event.pointerId); } catch { /* fine */ }
    }
    if (moved) strip.scrollLeft = at - by;
  });

  const release = (event) => {
    held = false;
    try { strip.releasePointerCapture(event.pointerId); } catch { /* fine */ }
  };
  strip.addEventListener('pointerup', release);
  strip.addEventListener('pointercancel', release);

  // Letting go over a button used to both scroll the strip and press
  // the button. Captured, so it is stopped before the button ever sees
  // it.
  strip.addEventListener('click', (event) => {
    if (!moved) return;
    event.preventDefault();
    event.stopPropagation();
    moved = false;
  }, true);
}
