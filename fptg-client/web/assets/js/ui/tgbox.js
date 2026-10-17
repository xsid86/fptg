import { el, clear } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { statusText } from './chat-list.js';
import { uploadRichFile } from './attach.js';

// Окно в духе «боксов» Telegram Desktop: одно модальное окно со стеком
// страниц (создание группы и канала — ui/newchat.js, управление —
// ui/manage.js). Шапка — «назад» (на вложенной странице), заголовок и
// крестик; тело прокручивается; кнопки — внизу справа, как у Desktop.
//
// Страница — { title, render(body, box) -> узлы, buttons: [{ label,
// run, primary, danger }] }. render зовётся при каждом показе (в том
// числе по возвращении «назад») и может быть async.

export function openBox() {
  const stack = [];
  const dialog = el('dialog', { class: 'tgbox' });
  const back = el('button', {
    class: 'btn btn--icon tgbox__back', type: 'button', title: 'Back', hidden: true,
    onclick: () => box.pop(),
  }, icon('chevron-left'));
  const title = el('h2', { class: 'tgbox__title' });
  const close = el('button', {
    class: 'btn btn--icon tgbox__close', type: 'button', title: 'Close',
    onclick: () => dialog.close(),
  }, icon('close'));
  // Фокус при открытии — на тело, не на крестик (иначе на нём рамка).
  const body = el('div', { class: 'tgbox__body', tabindex: '-1', autofocus: true });
  const foot = el('div', { class: 'tgbox__foot' });
  dialog.append(el('header', { class: 'tgbox__head' }, back, title, close), body, foot);
  dialog.addEventListener('close', () => dialog.remove());
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) dialog.close();
  });
  document.body.append(dialog);

  let seq = 0;
  const box = {
    dialog,
    /** Новая страница поверх. */
    push(page) {
      stack.push(page);
      return show();
    },
    /** Заменить текущую (шаг мастера без возврата). */
    replace(page) {
      stack.pop();
      stack.push(page);
      return show();
    },
    pop() {
      if (stack.length > 1) {
        stack.pop();
        show();
      } else {
        dialog.close();
      }
    },
    /** Перерисовать текущую (данные изменились). */
    refresh: () => show(),
    close: () => dialog.close(),
    get depth() { return stack.length; },
    /** Кнопки внизу недоступны, пока идёт запрос. */
    busy(on) {
      for (const b of foot.querySelectorAll('button')) b.disabled = on;
    },
  };

  async function show() {
    const my = ++seq;
    const page = stack[stack.length - 1];
    title.textContent = page.title ?? '';
    back.hidden = stack.length < 2;
    clear(body).append(el('p', { class: 'tgbox__hint' }, 'Loading…'));
    clear(foot);
    let nodes;
    try {
      nodes = await page.render(body, box);
    } catch (error) {
      if (my !== seq) return;
      clear(body).append(el('p', { class: 'tgbox__error' }, error?.message || String(error)));
      return;
    }
    if (my !== seq) return;
    clear(body).append(...[nodes].flat().filter(Boolean));
    body.scrollTop = 0;
    for (const b of page.buttons ?? []) {
      foot.append(el('button', {
        class: `btn tgbox__btn${b.primary ? ' is-primary' : ''}${b.danger ? ' is-danger' : ''}`,
        type: 'button',
        onclick: async () => {
          box.busy(true);
          try {
            await b.run(box);
          } catch (error) {
            showError(body, error);
          } finally {
            if (dialog.open) box.busy(false);
          }
        },
      }, b.label));
    }
    // Первое поле — в фокус, как у Desktop.
    body.querySelector('input:not([type="checkbox"]):not([type="radio"]), textarea')?.focus();
  }

  dialog.showModal();
  return box;
}

/** Ошибка на странице — сверху тела, до следующего показа. */
export function showError(body, error) {
  body.querySelector('.tgbox__error')?.remove();
  body.prepend(el('p', { class: 'tgbox__error', role: 'alert' }, error?.message || String(error)));
  body.scrollTop = 0;
}

// ------------------------------------------------------------ детали

/** Подпись раздела. */
export const section = (text) => el('div', { class: 'tgbox__section' }, text);

/** Пояснение под разделом. */
export const note = (text) => el('p', { class: 'tgbox__note' }, text);

/** Строка-переход: значок, подпись, значение справа. */
export function linkRow({ iconName, label, value = '', onClick, danger = false }) {
  return el('button', {
    class: `tgbox__row${danger ? ' is-danger' : ''}`, type: 'button', onclick: onClick,
  },
  iconName ? icon(iconName) : el('span', { class: 'tgbox__row-pad' }),
  el('span', { class: 'tgbox__row-label' }, label),
  value !== '' ? el('span', { class: 'tgbox__row-value' }, String(value)) : null);
}

/** Переключатель строкой; .checked — у возвращённого input. */
export function toggleRow(label, checked, { sub = '', disabled = false, onChange } = {}) {
  const input = el('input', { type: 'checkbox', class: 'tgbox__switch', checked, disabled });
  if (onChange) input.addEventListener('change', () => onChange(input.checked));
  const node = el('label', { class: `tgbox__toggle${disabled ? ' is-disabled' : ''}` },
    el('span', { class: 'tgbox__toggle-text' },
      el('span', { class: 'tgbox__row-label' }, label),
      sub ? el('span', { class: 'tgbox__row-sub' }, sub) : null),
    input);
  return { node, input };
}

/** Радиокнопки: [{ value, label, sub }]; .value() — выбранное. */
export function radioGroup(name, options, value, onChange) {
  const inputs = [];
  const node = el('div', { class: 'tgbox__radios' }, ...options.map((o) => {
    const input = el('input', { type: 'radio', name, value: o.value, checked: o.value === value });
    input.addEventListener('change', () => onChange?.(o.value));
    inputs.push(input);
    return el('label', { class: 'tgbox__radio' }, input,
      el('span', { class: 'tgbox__toggle-text' },
        el('span', { class: 'tgbox__row-label' }, o.label),
        o.sub ? el('span', { class: 'tgbox__row-sub' }, o.sub) : null));
  }));
  return { node, value: () => inputs.find((i) => i.checked)?.value };
}

/** Поле с подписью-подсказкой; prefix — неизменяемое начало (t.me/). */
export function textField(placeholder, value = '', { multiline = false, prefix = '', max = 0 } = {}) {
  const input = el(multiline ? 'textarea' : 'input', {
    class: 'tgbox__input', placeholder, value, rows: multiline ? 3 : undefined,
    maxLength: max || undefined, autocomplete: 'off', spellcheck: !prefix,
  });
  const node = el('label', { class: `tgbox__field${prefix ? ' has-prefix' : ''}` },
    prefix ? el('span', { class: 'tgbox__prefix' }, prefix) : null, input);
  return { node, input };
}

/** Человек или чат строкой: аватарка, имя, вторая строка, справа — метка. */
export function peerRow(card, { sub, right, onClick, checkbox } = {}) {
  const name = card.title || card.name || 'Deleted account';
  const avatar = el('span', { class: `avatar tgbox__avatar accent-${card.color || 'a5'}` });
  fillAvatar(avatar, { id: card.id ?? card.userId, title: name, avatar: card.avatar || '', avatarThumb: card.avatarThumb || '' });
  const subText = sub ?? (card.status ? statusText(card) : '');
  const parts = [
    checkbox ?? null,
    avatar,
    el('span', { class: 'tgbox__toggle-text' },
      el('span', { class: 'tgbox__row-label' }, name),
      subText ? el('span', { class: `tgbox__row-sub${card.status === 'userStatusOnline' ? ' is-online' : ''}` }, subText) : null),
    right ? el('span', { class: 'tgbox__row-value' }, right) : null,
  ];
  if (checkbox) return el('label', { class: 'tgbox__peer' }, ...parts);
  return el('button', { class: 'tgbox__peer', type: 'button', onclick: onClick, disabled: !onClick }, ...parts);
}

/**
 * Фото группы или канала: круг с камерой, по щелчку — выбор файла, он
 * сразу грузится (POST /upload). .upload() — id загрузки или ''.
 */
export function photoPicker(current = null) {
  const circle = el('span', { class: 'avatar tgbox__photo' });
  if (current) fillAvatar(circle, current);
  else circle.append(icon('image'));
  const picker = el('input', { type: 'file', accept: 'image/*', hidden: true });
  let pending = null;
  let preview = '';
  picker.addEventListener('change', () => {
    const file = picker.files?.[0];
    picker.value = '';
    if (!file) return;
    if (preview) URL.revokeObjectURL(preview);
    preview = URL.createObjectURL(file);
    clear(circle).append(el('img', { class: 'avatar__img', src: preview, alt: '' }));
    pending = uploadRichFile(file).then((r) => r.id);
  });
  const node = el('button', {
    class: 'tgbox__photo-btn', type: 'button', title: 'Choose photo',
    onclick: () => picker.click(),
  }, circle, picker);
  return { node, upload: async () => (pending ? pending : ''), changed: () => pending !== null };
}

/** Удобная обёртка для admin: шаги -> ответы TDLib по ключам. */
export function adminCall(call, steps) {
  return call('admin', { steps });
}

/**
 * Список контактов с галочками, поиском и счётчиком «N / max», как
 * «Add Members» у Desktop. .chosen() — выбранные id (строки).
 */
export async function contactPicker(call, { max = 200000, exclude = new Set() } = {}) {
  const answer = await call('contacts.list');
  const people = (answer?.contacts ?? []).filter((c) => !exclude.has(String(c.userId)))
    .sort((a, b) => (a.title || '').localeCompare(b.title || ''));
  const chosen = new Set();
  const counter = el('span', { class: 'tgbox__counter' }, `0 / ${max}`);
  const search = el('input', { class: 'tgbox__input', type: 'search', placeholder: 'Search', autocomplete: 'off' });
  const list = el('div', { class: 'tgbox__list' }, ...people.map((p) => {
    const box = el('input', { type: 'checkbox', class: 'tgbox__check' });
    box.addEventListener('change', () => {
      if (box.checked) chosen.add(String(p.userId));
      else chosen.delete(String(p.userId));
      counter.textContent = `${chosen.size} / ${max}`;
    });
    const row = peerRow(p, { checkbox: box });
    row.dataset.name = `${p.title || ''} ${p.username || ''}`.toLowerCase();
    return row;
  }));
  search.addEventListener('input', () => {
    const q = search.value.trim().toLowerCase();
    for (const row of list.children) row.hidden = !!q && !row.dataset.name.includes(q);
  });
  const nodes = [
    el('div', { class: 'tgbox__search' }, el('label', { class: 'tgbox__field' }, search), counter),
    people.length ? list : note('No contacts yet.'),
  ];
  return { nodes, chosen: () => [...chosen] };
}
