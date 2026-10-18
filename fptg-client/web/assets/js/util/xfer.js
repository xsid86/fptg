import { fileSize } from './format.js';

// A file transfer's progress — a download or an upload: a ring around the
// icon and "how much of how much".
//
// The data — the xfer field of a message's media ({done, total, up}), which
// the server sends only while the transfer runs (MediaJson in webapi.pas,
// ApplyXferFile in tdmessages.pas).
//
// The ring is SVG, and the share is set by the stroke-dashoffset ATTRIBUTE,
// not style: the circle has pathLength="100", so the offset is straight
// percent, and the ring moves smoothly, without the .w-* class ladder. The
// same trick as <progress value> for audio.

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

/** An SVG ring for the share x. It goes inside the icon — see addRing. */
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
 * Puts the ring on an icon (a file disc, an audio button, a download button
 * on a picture). On upload the icon's arrow turns upwards (.is-up in the styles).
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
