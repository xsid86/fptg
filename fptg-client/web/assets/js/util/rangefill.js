// Заливка ползунка до бегунка (components/_inputrange.scss, $track-bg).
//
// У ползунка Chromium нет отдельной части «до бегунка» — её рисует
// градиент дорожки, а ему нужен процент: переменная --range-fill.
// Атрибута style в проекте нет, поэтому значения живут в одной
// принятой таблице стилей — правило на ползунок, по data-fill — тот
// же приём, что у маркера меню (util/menu.js).

// Ширина бегунка — $thumb-width в _inputrange.scss: центр бегунка ходит
// от половины его ширины до «ширина дорожки минус половина».
const THUMB_W = 8;

let sheet = null;
let next = 1;
const values = new Map();   // id -> css значение --range-fill

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

/** Подключить заливку к ползунку: сейчас и при каждом движении. */
export function trackFill(input) {
  if (!input.dataset.fill) input.dataset.fill = String(next++);
  input.addEventListener('input', () => update(input));
  update(input);
  return input;
}

/** Забыть ползунки, которых больше нет в документе. */
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
