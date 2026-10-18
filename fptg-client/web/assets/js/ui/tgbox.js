import { el, clear } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { fillAvatar } from '../util/avatar.js';
import { statusText } from './chat-list.js';
import { uploadRichFile } from './attach.js';

// A window in the spirit of Telegram Desktop's "boxes": one modal window
// with a stack of pages (creating a group and a channel — ui/newchat.js,
// management — ui/manage.js). The header — "back" (on a nested page), the
// title and a cross; the body scrolls; the buttons — at the bottom right,
// as in Desktop.
//
// A transition between pages is as between windows: the old one fades
// (FADE_OUT_MS), the new one fades in (CSS, .tgbox.is-leaving); together —
// under half a second. Redrawing the same page (refresh) — without it.
//
// A page is { title, render(body, box) -> nodes, buttons: [{ label, run,
// primary, danger }] }. render is called on every showing (including on
// coming "back") and may be async.

const FADE_OUT_MS = 150;
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

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
  // Focus on opening — on the body, not on the cross (otherwise it gets a ring).
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
    /** A new page on top. */
    push(page) {
      stack.push(page);
      return show(true);
    },
    /** Replace the current one (a wizard step without return). */
    replace(page) {
      stack.pop();
      stack.push(page);
      return show(true);
    },
    pop() {
      if (stack.length > 1) {
        stack.pop();
        show(true);
      } else {
        dialog.close();
      }
    },
    /** Redraw the current one (the data changed). */
    refresh: () => show(),
    close: () => dialog.close(),
    get depth() { return stack.length; },
    /** The buttons at the bottom are unavailable while a request runs. */
    busy(on) {
      for (const b of foot.querySelectorAll('button')) b.disabled = on;
    },
  };

  let shown = false;

  async function show(animate = false) {
    const my = ++seq;
    const page = stack[stack.length - 1];
    // The first page — "Loading…" while it prepares; after that the old
    // page stays in place (the window is "busy") until the new one is ready
    // whole — the data loaded, the nodes built — and only then the
    // transition: the old one fades, the new one fades in. Otherwise the
    // window changed before content appeared in it, and the transition jerked.
    if (!shown) {
      title.textContent = page.title ?? '';
      clear(body).append(el('p', { class: 'tgbox__hint' }, 'Loading…'));
    } else {
      dialog.classList.add('is-busy');
    }
    let nodes;
    try {
      nodes = await page.render(body, box);
    } catch (error) {
      nodes = el('p', { class: 'tgbox__error' }, error?.message || String(error));
    }
    if (my !== seq) return;
    dialog.classList.remove('is-busy');
    if (animate && shown) {
      dialog.classList.add('is-leaving');
      await wait(FADE_OUT_MS);
      if (my !== seq) return;
    }
    title.textContent = page.title ?? '';
    back.hidden = stack.length < 2;
    clear(body).append(...[nodes].flat().filter(Boolean));
    body.scrollTop = 0;
    clear(foot);
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
    shown = true;
    dialog.classList.remove('is-leaving');
    // The first field — focused, as in Desktop.
    body.querySelector('input:not([type="checkbox"]):not([type="radio"]), textarea')?.focus();
  }

  dialog.showModal();
  return box;
}

/** An error on the page — at the top of the body, until the next showing. */
export function showError(body, error) {
  body.querySelector('.tgbox__error')?.remove();
  body.prepend(el('p', { class: 'tgbox__error', role: 'alert' }, error?.message || String(error)));
  body.scrollTop = 0;
}

// ------------------------------------------------------------ parts

/** A section label. */
export const section = (text) => el('div', { class: 'tgbox__section' }, text);

/** A note under a section. */
export const note = (text) => el('p', { class: 'tgbox__note' }, text);

/** A link row: an icon, a label, a value on the right. */
export function linkRow({ iconName, label, value = '', onClick, danger = false }) {
  return el('button', {
    class: `tgbox__row${danger ? ' is-danger' : ''}`, type: 'button', onclick: onClick,
  },
  iconName ? icon(iconName) : el('span', { class: 'tgbox__row-pad' }),
  el('span', { class: 'tgbox__row-label' }, label),
  value !== '' ? el('span', { class: 'tgbox__row-value' }, String(value)) : null);
}

/** A toggle as a row; .checked — on the returned input. */
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

/** Radio buttons: [{ value, label, sub }]; .value() — the chosen one. */
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

/** A field with a placeholder label; prefix — an unchangeable start (t.me/). */
export function textField(placeholder, value = '', { multiline = false, prefix = '', max = 0 } = {}) {
  const input = el(multiline ? 'textarea' : 'input', {
    class: 'tgbox__input', placeholder, value, rows: multiline ? 3 : undefined,
    maxLength: max || undefined, autocomplete: 'off', spellcheck: !prefix,
  });
  const node = el('label', { class: `tgbox__field${prefix ? ' has-prefix' : ''}` },
    prefix ? el('span', { class: 'tgbox__prefix' }, prefix) : null, input);
  return { node, input };
}

/** A person or chat as a row: avatar, name, a second line, a mark on the right. */
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
 * A group or channel photo: a circle with a camera, a click — a file choice,
 * it uploads at once (POST /upload). .upload() — the upload id or ''.
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

/** A handy wrapper for admin: steps -> TDLib answers by keys. */
export function adminCall(call, steps) {
  return call('admin', { steps });
}

/**
 * A contact list with checkboxes, search and an "N / max" counter, like
 * "Add Members" in Desktop. .chosen() — the chosen ids (strings).
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
