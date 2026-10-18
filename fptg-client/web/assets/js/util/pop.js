// Where a pop-up went — up or down from its anchor. Call right after
// showPopover(), in the same task: the rectangles are computed already,
// while the frame is not painted yet, and the appearance animation
// (components/_pop.scss) goes in the right direction at once. Above the
// anchor — the is-pop-up class (sliding in from below), otherwise without
// it (sliding in from above).
//
// The place is decided by CSS (position-area and position-try-fallbacks),
// so it can only be learned by measuring, not in advance.
export function markPopDirection(node, anchor) {
  if (!node || !anchor) return;
  const box = node.getBoundingClientRect();
  const at = anchor.getBoundingClientRect();
  node.classList.toggle('is-pop-up', box.top < at.top);
}
