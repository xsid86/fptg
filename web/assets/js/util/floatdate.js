// Плавающая дата: день, элементы которого сейчас наверху прокрутки, —
// одним ярлыком на `offset` пикселей ниже её верхнего края. Общая для
// истории (ui/history.js) и медиа в панели информации (ui/infopanel.js).
//
// Не position: sticky на самих разделителях — они все на одном уровне
// и в конце концов склеивались в пачку. Ярлык один, лежит поверх
// прокрутки, а скрипт решает, что на нём написано и виден ли он:
//   * день — у последнего дневного разделителя, ушедшего выше линии
//     ярлыка;
//   * ярлык прячется, пока настоящий разделитель этого дня ещё виден
//     на своём месте, и когда следующий подъезжает к ярлыку снизу — там
//     уже стоит настоящий, и два одинаковых рядом не нужны.
// Сдвигать ярлык не приходится, поэтому и style не нужен.
//
// Разделитель — элемент с data-day (текст дня), его первый потомок —
// видимая плашка. Ярлык — элемент с одним потомком, в который пишется
// день; прячется атрибутом hidden.

// Высота ярлыка, пока он ни разу не был показан и измерить его нечем.
const CHIP_FALLBACK_PX = 24;
// Зазор, на котором подъезжающий снизу разделитель уже «встал» на ярлык.
const CHIP_GAP_PX = 4;

/**
 * scroller — прокручиваемый элемент; scope — где искать разделители;
 * float — сам ярлык; offset — его расстояние от верха scroller (то же,
 * что top у ярлыка в CSS).
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
    // Свой разделитель дня ещё виден — дата и так на экране.
    && current.label.bottom <= top
    // Следующий день подъезжает к ярлыку — на этом месте уже он.
    && !(next && next.top < line + chipHeight + CHIP_GAP_PX);
  if (show && chip.textContent !== current.sep.dataset.day) {
    chip.textContent = current.sep.dataset.day;
  }
  float.hidden = !show;
}
