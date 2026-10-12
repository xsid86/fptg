// Куда всплыло окно — вверх или вниз от своего якоря. Звать сразу после
// showPopover(), в той же задаче: прямоугольники уже посчитаны, а кадр
// ещё не нарисован, и анимация появления (components/_pop.scss) сразу
// пойдёт в нужную сторону. Над якорем — класс is-pop-up (въезд снизу),
// иначе без него (въезд сверху).
//
// Место решает CSS (position-area и position-try-fallbacks), поэтому
// узнать его можно только измерив, а не заранее.
export function markPopDirection(node, anchor) {
  if (!node || !anchor) return;
  const box = node.getBoundingClientRect();
  const at = anchor.getBoundingClientRect();
  node.classList.toggle('is-pop-up', box.top < at.top);
}
