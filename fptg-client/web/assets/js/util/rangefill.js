// The slider's fill up to the thumb (components/_inputrange.scss, $track-bg).
//
// A Chromium slider has no separate "before the thumb" part — the track's
// gradient draws it, and it needs a percent: the --range-fill variable.
// There is no style attribute in the project, so the values live in one
// adopted style sheet — a rule per slider, by data-fill — the same trick
// as the menu marker (util/menu.js).

// The thumb width — $thumb-width in _inputrange.scss: the thumb's centre
// moves from half its width to "the track width minus a half".
const THUMB_W = 8;

let sheet = null;
let next = 1;
const values = new Map();   // id -> the css value of --range-fill

function flush() {
  if (!sheet) {
    sheet = new CSSStyleSheet();
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  }
  const rules = [];
  for (const [id, v] of values) rules.push(`[data-fill="${id}"]{--range-fill:${v}}`);
  sheet.replaceSync(rules.join('\n'));
}

function update(input) {
  const min = Number(input.min || 0);
  const max = Number(input.max || 100);
  const p = max > min ? ((Number(input.value) - min) / (max - min)) * 100 : 0;
  const shift = ((0.5 - p / 100) * THUMB_W).toFixed(2);
  values.set(input.dataset.fill, `calc(${p.toFixed(2)}% + ${shift}px)`);
  flush();
}

/** Attach the fill to a slider: now and on every movement. */
export function trackFill(input) {
  if (!input.dataset.fill) input.dataset.fill = String(next++);
  input.addEventListener('input', () => update(input));
  update(input);
  return input;
}

/** Forget the sliders no longer in the document. */
export function pruneFills() {
  let changed = false;
  for (const id of [...values.keys()]) {
    if (!document.querySelector(`[data-fill="${id}"]`)) {
      values.delete(id);
      changed = true;
    }
  }
  if (changed) flush();
}
