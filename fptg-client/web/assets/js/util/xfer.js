import { fileSize } from './format.js';

// Ход передачи файла — скачивания или закачки: кольцо вокруг значка и
// «сколько из скольких».
//
// Данные — поле xfer у медиа сообщения ({done, total, up}), которое
// сервер присылает, только пока передача идёт (MediaJson в webapi.pas,
// ApplyXferFile в tdmessages.pas).
//
// Кольцо — SVG, и долю задаёт АТРИБУТ stroke-dashoffset, а не style:
// у окружности pathLength="100", так что смещение — прямо проценты, и
// кольцо движется плавно, без лестницы классов .w-*. Та же уловка, что
// <progress value> у аудио.

const SVG = 'http://www.w3.org/2000/svg';

const fraction = (x) => (x?.total > 0 ? Math.min(1, Math.max(0, x.done / x.total)) : 0);

function circle(cls) {
  const c = document.createElementNS(SVG, 'circle');
  c.setAttribute('class', cls);
  c.setAttribute('cx', '50');
  c.setAttribute('cy', '50');
  c.setAttribute('r', '46');
  c.setAttribute('pathLength', '100');
  return c;
}

/** SVG-кольцо для доли x. Кладётся внутрь значка — см. addRing. */
export function ringNode(x) {
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('class', 'xfer__ring');
  svg.setAttribute('viewBox', '0 0 100 100');
  svg.setAttribute('aria-hidden', 'true');
  const fill = circle('xfer__fill');
  fill.setAttribute('stroke-dasharray', '100');
  fill.setAttribute('stroke-dashoffset', String(100 - fraction(x) * 100));
  svg.append(circle('xfer__track'), fill);
  return svg;
}

/**
 * Надевает кольцо на значок (диск файла, кнопку аудио, кнопку загрузки
 * на картинке). При закачке стрелка значка разворачивается вверх
 * (.is-up в стилях).
 */
export function addRing(node, x) {
  if (!node || !x) return node;
  node.classList.add('xfer');
  if (x.up) node.classList.add('is-up');
  node.append(ringNode(x));
  return node;
}

/** «12.3 MB / 58.1 MB» */
export const xferText = (x) => `${fileSize(x.done)} / ${fileSize(x.total)}`;

/** «45.8 MB left» */
export const xferLeft = (x) => `${fileSize(Math.max(0, x.total - x.done))} left`;
