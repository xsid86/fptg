// Кольцо историй вокруг аватарки: по сегменту на активную историю,
// прочитанные — серые, непрочитанные — цветом (components/_story-ring.scss:
// цвет контакта в цветных темах, акцент в простых и Aurora).
//
// SVG, а не градиент: число сегментов любое и у каждого своё состояние.
// Дуги — штрих окружности: stroke-dasharray / stroke-dashoffset —
// АТРИБУТЫ SVG, не style (правило проекта о style не нарушается); цвет —
// в CSS. Толщина — здесь же, атрибутом: от неё зависит зазор (см. GAP).

const NS = 'http://www.w3.org/2000/svg';
const VIEW = 100;
const RADIUS = 47;                 // кольцо по краю viewBox
const STROKE = 5;                  // толщина дуги, единицы viewBox (100 = вся аватарка)
// Видимый зазор между сегментами. Круглые концы выступают на STROKE/2 с
// каждой стороны и съели бы его — к штриху прибавляется ещё STROKE.
const GAP = 9;
const LENGTH = 2 * Math.PI * RADIUS;
// Длина окружности для штрихов — ровно PATH (атрибут pathLength): браузер
// строит круг кривыми, и его настоящая длина чуть отличается от 2πR —
// без этого ошибка копилась по кругу, и зазоры выходили разными
// (замер на холсте: 96px — 8.8..10.3° против 10.0..10.2°).
const PATH = 100;
const UNIT = PATH / LENGTH;        // единицы viewBox -> единицы PATH

function svgEl(tag, attrs) {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  return node;
}

/**
 * Обёртка с кольцом вокруг уже готовой аватарки. total — сколько
 * историй, read — сколько из них прочитано (старые идут первыми — их
 * сегменты первые от верха по часовой стрелке).
 */
export function storyRing(avatarNode, total, read) {
  const box = document.createElement('span');
  box.className = `story-ring${read >= total ? ' is-read' : ''}`;
  const svg = svgEl('svg', { class: 'story-ring__svg', viewBox: `0 0 ${VIEW} ${VIEW}`, 'aria-hidden': 'true' });
  const step = PATH / total;
  const gap = total > 1 ? (GAP + STROKE) * UNIT : 0;
  const dash = Math.max(step - gap, 0.01);
  for (let i = 0; i < total; i += 1) {
    svg.append(svgEl('circle', {
      class: `story-ring__seg${i < read ? ' is-read' : ''}`,
      cx: VIEW / 2, cy: VIEW / 2, r: RADIUS, 'stroke-width': STROKE, pathLength: PATH,
      'stroke-dasharray': `${dash} ${PATH - dash}`,
      // От верха (поворот -90°), по часовой; половина зазора — с каждой стороны.
      'stroke-dashoffset': -(i * step + gap / 2),
      transform: `rotate(-90 ${VIEW / 2} ${VIEW / 2})`,
    }));
  }
  box.title = total === 1 ? '1 story' : `${total} stories`;
  box.append(svg, avatarNode);
  return box;
}
