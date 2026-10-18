// The story ring around an avatar: one segment per active story, read
// ones — grey, unread ones — in colour (components/_story-ring.scss: the
// contact's colour in colour themes, the accent in plain ones and Aurora).
//
// SVG, not a gradient: the number of segments is any, and each has its own
// state. The arcs are a circle's stroke: stroke-dasharray /
// stroke-dashoffset are SVG ATTRIBUTES, not style (the project's style rule
// is not broken); the colour — in CSS. The width — here too, as an
// attribute. The arc ends are flat (CSS: stroke-linecap: butt): a round tip
// at 48px is smoothed unevenly, and the gaps looked different.

const NS = 'http://www.w3.org/2000/svg';
const VIEW = 100;
const RADIUS = 47;                 // the ring along the edge of the viewBox
const STROKE = 5;                  // the arc width, viewBox units (100 = the whole avatar)
// The gap between segments — the flat ends do not stick out, it is exactly this.
const GAP = 9;
const LENGTH = 2 * Math.PI * RADIUS;
// The circumference for the strokes is exactly PATH (the pathLength
// attribute): the browser builds the circle from curves, and its real length
// differs slightly from 2πR — without this the error accumulated around the
// circle, and the gaps came out different (measured on a canvas: 96px —
// 8.8..10.3° against 10.0..10.2°).
const PATH = 100;
const UNIT = PATH / LENGTH;        // viewBox units -> PATH units

function svgEl(tag, attrs) {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  return node;
}

/**
 * A wrapper with a ring around an already ready avatar. total — how many
 * stories, read — how many of them are read (old ones go first — their
 * segments are the first from the top clockwise).
 */
export function storyRing(avatarNode, total, read) {
  const box = document.createElement('span');
  box.className = `story-ring${read >= total ? ' is-read' : ''}`;
  const svg = svgEl('svg', { class: 'story-ring__svg', viewBox: `0 0 ${VIEW} ${VIEW}`, 'aria-hidden': 'true' });
  const step = PATH / total;
  const gap = total > 1 ? GAP * UNIT : 0;
  const dash = Math.max(step - gap, 0.01);
  for (let i = 0; i < total; i += 1) {
    svg.append(svgEl('circle', {
      class: `story-ring__seg${i < read ? ' is-read' : ''}`,
      cx: VIEW / 2, cy: VIEW / 2, r: RADIUS, 'stroke-width': STROKE, pathLength: PATH,
      'stroke-dasharray': `${dash} ${PATH - dash}`,
      // From the top (a -90° rotation), clockwise; half the gap — on each side.
      'stroke-dashoffset': -(i * step + gap / 2),
      transform: `rotate(-90 ${VIEW / 2} ${VIEW / 2})`,
    }));
  }
  box.title = total === 1 ? '1 story' : `${total} stories`;
  box.append(svg, avatarNode);
  return box;
}
