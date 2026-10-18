// The floating date: the day whose elements are now at the top of the
// scroll — as one label `offset` pixels below its top edge. Shared by the
// history (ui/history.js) and the media in the info panel (ui/infopanel.js).
//
// Not position: sticky on the dividers themselves — they are all on one
// level and in the end stuck together in a stack. The label is one, lies
// over the scroll, and the script decides what is written on it and
// whether it is visible:
//   * the day — of the last day divider that went above the label's line;
//   * the label hides while that day's real divider is still visible in
//     its place, and when the next one approaches the label from below —
//     the real one stands there already, and two identical ones side by
//     side are not needed.
// The label never has to be moved, so no style is needed either.
//
// A divider is an element with data-day (the day's text), its first child
// is the visible plate. The label is an element with one child the day is
// written into; it hides with the hidden attribute.

// The label's height while it has never been shown and there is nothing to measure it by.
const CHIP_FALLBACK_PX = 24;
// The gap at which a divider approaching from below has "landed" on the label.
const CHIP_GAP_PX = 4;

/**
 * scroller — the scrolling element; scope — where to look for dividers;
 * float — the label itself; offset — its distance from the top of scroller
 * (the same as the label's top in CSS).
 */
export function updateFloatDate(scroller, scope, float, offset) {
  if (!float || !scroller || !scope) return;
  const top = scroller.getBoundingClientRect().top;
  const line = top + offset;
  const chip = float.firstElementChild;
  const chipHeight = float.hidden
    ? CHIP_FALLBACK_PX
    : (chip.getBoundingClientRect().height || CHIP_FALLBACK_PX);

  let current = null;
  let next = null;
  for (const sep of scope.querySelectorAll('[data-day]')) {
    const label = sep.firstElementChild.getBoundingClientRect();
    if (label.top < line) current = { sep, label };
    else {
      next = label;
      break;
    }
  }

  const show = !!current
    // The day's own divider is still visible — the date is on screen anyway.
    && current.label.bottom <= top
    // The next day approaches the label — it is in that place already.
    && !(next && next.top < line + chipHeight + CHIP_GAP_PX);
  if (show && chip.textContent !== current.sep.dataset.day) {
    chip.textContent = current.sep.dataset.day;
  }
  // The day's midnight (data-date, if the divider carries it) — the label
  // with it is clickable (a jump to the day's first message, ui/history.js).
  if (show && current.sep.dataset.date) float.dataset.date = current.sep.dataset.date;
  else delete float.dataset.date;
  float.hidden = !show;
}
