import { customEmojiNode } from '../util/emoji.js';
import { getPref } from '../util/prefs.js';

// Поле ввода сообщения: contenteditable, который показывает результат,
// а не разметку — жирный жирным, кастомный эмодзи картинкой.
//
// МОДЕЛЬ — текст и сущности (как у Telegram): { text, entities }, где
// сущность — { kind, offset, length, ...поля вида }, смещения в UTF-16 (в
// них же считает TDLib, и это длина строки JS). DOM — только её вид:
// любое изменение оформления идёт через модель (getFormatted -> правка
// -> setFormatted), а набор текста — обычный, браузерный; DOM читается
// обратно в модель (scan) в момент, когда она нужна.
//
// Снаружи элемент притворяется textarea: value, placeholder, disabled,
// selectionStart/End, setSelectionRange — на это опираются подсказка
// упоминаний, инлайн-боты и вставки (ui/mentions.js, ui/bots.js).
//
// Виды сущностей: bold, italic, underline, strike, code, pre, spoiler,
// quote, textUrl {url}, mentionName {userId}, customEmoji {customEmojiId}.
//
// Быстрые клавиши набора — как у Telegram Desktop: **жирный**,
// __курсив__, ~~зачёркнутый~~, ||спойлер||, `моно`; одиночные *, _, ~ —
// просто символы. Сочетания: Ctrl+B/I/U, Ctrl+Shift+X (зачёркнутый),
// Ctrl+Shift+M (моно), Ctrl+Shift+P (спойлер), Ctrl+K (ссылка),
// Ctrl+Shift+N (снять оформление).

const ZWSP = '​';
// Порядок вложения элементов: внешние — первыми.
const ORDER = ['quote', 'pre', 'textUrl', 'mentionName', 'bold', 'italic',
  'underline', 'strike', 'spoiler', 'code'];
const INLINE_KINDS = new Set(['bold', 'italic', 'underline', 'strike', 'spoiler', 'code']);
// Чем снимается «Clear»: всё, кроме того, что несёт смысл, а не вид.
const CLEARABLE = new Set([...INLINE_KINDS, 'pre', 'quote', 'textUrl']);
// Пауза, после которой набор текста — новый шаг отмены.
const UNDO_GAP_MS = 800;
const UNDO_MAX = 100;

const SHORTCUTS = [
  { re: /\*\*(\S(?:[^\n]*?\S)?)\*\*$/, kind: 'bold', mark: 2 },
  { re: /__(\S(?:[^\n]*?\S)?)__$/, kind: 'italic', mark: 2 },
  { re: /~~(\S(?:[^\n]*?\S)?)~~$/, kind: 'strike', mark: 2 },
  { re: /\|\|(\S(?:[^\n]*?\S)?)\|\|$/, kind: 'spoiler', mark: 2 },
  { re: /(?<!`)`([^`\n]+)`$/, kind: 'code', mark: 1 },
];

/** Одна сущность — один элемент (вид и поля). */
function elementFor(e) {
  switch (e.kind) {
    case 'bold': return document.createElement('b');
    case 'italic': return document.createElement('i');
    case 'underline': return document.createElement('u');
    case 'strike': return document.createElement('s');
    case 'code': return document.createElement('code');
    case 'spoiler': return mk('span', 'ed-spoiler');
    case 'pre': {
      const n = mk('span', 'ed-pre');
      if (e.language) n.dataset.language = e.language;
      return n;
    }
    case 'quote': return mk('span', 'ed-quote');
    case 'textUrl': {
      const n = mk('a', 'ed-link');
      n.dataset.url = e.url ?? '';
      n.title = e.url ?? '';
      return n;
    }
    case 'mentionName': {
      const n = mk('a', 'ed-mention');
      n.dataset.userId = String(e.userId ?? '');
      return n;
    }
    default: return mk('span', '');
  }
}

function mk(tag, cls) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  return n;
}

/** Элемент DOM -> вид сущности (или null — просто обёртка). */
function kindOf(node) {
  const tag = node.nodeName;
  if (tag === 'B' || tag === 'STRONG') return { kind: 'bold' };
  if (tag === 'I' || tag === 'EM') return { kind: 'italic' };
  if (tag === 'U') return { kind: 'underline' };
  if (tag === 'S' || tag === 'STRIKE' || tag === 'DEL') return { kind: 'strike' };
  if (tag === 'CODE') return { kind: 'code' };
  const cls = node.classList;
  if (!cls) return null;
  if (cls.contains('ed-spoiler')) return { kind: 'spoiler' };
  if (cls.contains('ed-pre')) return { kind: 'pre', language: node.dataset.language || '' };
  if (cls.contains('ed-quote')) return { kind: 'quote' };
  if (cls.contains('ed-link')) return { kind: 'textUrl', url: node.dataset.url || '' };
  if (cls.contains('ed-mention')) return { kind: 'mentionName', userId: node.dataset.userId || '' };
  return null;
}

const sameProps = (a, b) => a.kind === b.kind && (a.url ?? '') === (b.url ?? '')
  && String(a.userId ?? '') === String(b.userId ?? '')
  && String(a.customEmojiId ?? '') === String(b.customEmojiId ?? '')
  && (a.language ?? '') === (b.language ?? '');

/** Сортировка и склейка соседних/перекрытых сущностей одного вида. */
export function normalizeEntities(list) {
  const out = [];
  const sorted = list.filter((e) => e.length > 0)
    .sort((a, b) => a.offset - b.offset || b.length - a.length);
  for (const e of sorted) {
    const prev = out.findLast((p) => sameProps(p, e) && e.kind !== 'customEmoji');
    if (prev && prev.offset + prev.length >= e.offset) {
      prev.length = Math.max(prev.length, e.offset + e.length - prev.offset);
    } else {
      out.push({ ...e });
    }
  }
  return out.sort((a, b) => a.offset - b.offset);
}

/**
 * Вырезать [a, b) и вставить insLen символов: сущности сдвигаются,
 * обрезаются; вставка внутри сущности её продолжает. Кастомный эмодзи,
 * задетый правкой, пропадает целиком (он атомарен).
 */
export function spliceEntities(list, a, b, insLen) {
  const delta = insLen - (b - a);
  const out = [];
  for (const e of list) {
    const s = e.offset;
    const t = e.offset + e.length;
    if (t <= a) {
      out.push({ ...e });
    } else if (s >= b) {
      out.push({ ...e, offset: s + delta });
    } else if (e.kind === 'customEmoji') {
      // задет — пропадает
    } else if (s < a && t > b) {
      out.push({ ...e, length: e.length + delta });
    } else {
      if (s < a) out.push({ ...e, length: a - s });
      if (t > b) out.push({ ...e, offset: b + delta, length: t - b });
    }
  }
  return normalizeEntities(out);
}

/** Есть ли вид kind на всём [a, b). */
function covers(list, kind, a, b) {
  const spans = list.filter((e) => e.kind === kind).map((e) => [e.offset, e.offset + e.length])
    .sort((x, y) => x[0] - y[0]);
  let pos = a;
  for (const [s, t] of spans) {
    if (s > pos) break;
    if (t > pos) pos = t;
    if (pos >= b) return true;
  }
  return pos >= b;
}

/** Снять вид kind с [a, b) (части сущностей вне диапазона остаются). */
function removeKind(list, kinds, a, b) {
  const out = [];
  for (const e of list) {
    const s = e.offset;
    const t = e.offset + e.length;
    if (!kinds.has(e.kind) || t <= a || s >= b) {
      out.push(e);
      continue;
    }
    if (s < a) out.push({ ...e, length: a - s });
    if (t > b) out.push({ ...e, offset: b, length: t - b });
  }
  return out;
}

class FptgEditor extends HTMLElement {
  constructor() {
    super();
    this._undo = [];
    this._redo = [];
    this._lastSnap = 0;
    this._saved = null;      // последнее выделение, пока фокус не здесь
    this._disabled = false;
  }

  connectedCallback() {
    if (this._ready) return;
    this._ready = true;
    this.setAttribute('role', 'textbox');
    this.setAttribute('aria-multiline', 'true');
    this.contentEditable = this._disabled ? 'false' : 'true';
    this.spellcheck = true;
    if (this.hasAttribute('placeholder')) {
      this.dataset.placeholder = this.getAttribute('placeholder');
      this.removeAttribute('placeholder');
    }
    this.addEventListener('beforeinput', (e) => this._beforeInput(e));
    this.addEventListener('input', (e) => this._afterInput(e));
    this.addEventListener('keydown', (e) => this._keys(e));
    this.addEventListener('paste', (e) => this._paste(e));
    document.addEventListener('selectionchange', () => {
      if (this._hasSelection()) this._saved = this._offsets();
    });
    // Файл эмодзи догрузился — запасной символ меняется на картинку.
    document.addEventListener('custom-emoji:ready', () => this._refreshEmoji());
  }

  // --------------------------------------------- как у textarea
  get value() { return this._scan().text; }

  set value(text) {
    this._snapshot(true);
    this.setFormatted({ text: String(text ?? ''), entities: [] });
    const end = this.value.length;
    this.setSelectionRange(end, end);
  }

  get placeholder() { return this.dataset.placeholder ?? ''; }

  set placeholder(text) { this.dataset.placeholder = text; }

  get disabled() { return this._disabled; }

  set disabled(on) {
    this._disabled = Boolean(on);
    this.contentEditable = on ? 'false' : 'true';
    this.toggleAttribute('disabled', this._disabled);
    this.setAttribute('aria-disabled', String(this._disabled));
  }

  get selectionStart() { return (this._current())[0]; }

  get selectionEnd() { return (this._current())[1]; }

  setSelectionRange(a, b = a) {
    this._saved = [a, b];
    const sel = document.getSelection();
    const start = this._position(a);
    const end = a === b ? start : this._position(b);
    if (!sel || !start || !end) return;
    const range = document.createRange();
    range.setStart(start[0], start[1]);
    range.setEnd(end[0], end[1]);
    sel.removeAllRanges();
    sel.addRange(range);
  }

  focus(options) {
    super.focus(options);
    if (this._saved) this.setSelectionRange(...this._saved);
  }

  // --------------------------------------------- модель
  /** Текст и сущности (смещения UTF-16). */
  getFormatted() {
    const { text, entities } = this._scan();
    return { text, entities: normalizeEntities(entities) };
  }

  /** Заменить содержимое моделью; выделение — в конец. */
  setFormatted({ text, entities = [] }) {
    const ents = normalizeEntities(entities.filter((e) => e.offset >= 0
      && e.offset + e.length <= text.length));
    this.replaceChildren(...this._build(text, 0, text.length, ents, 0));
    // Пустая последняя строка видна только с <br> после неё.
    if (text.endsWith('\n')) this.append(document.createElement('br'));
  }

  /**
   * Заменить [a, b) текстом (с сущностями внутри него, от 0) и поставить
   * курсор после. keepCaret — курсор остаётся, где был (сдвинутый на
   * разницу длины, если он дальше правки): замена, которую человек не
   * делал сам, — например, догрузившийся файл.
   */
  replaceRange(a, b, text, inner = [], { keepCaret = false } = {}) {
    const caret = keepCaret ? this._current() : null;
    this._snapshot(true);
    const doc = this.getFormatted();
    const entities = spliceEntities(doc.entities, a, b, text.length)
      .concat(inner.map((e) => ({ ...e, offset: e.offset + a })));
    this.setFormatted({ text: doc.text.slice(0, a) + text + doc.text.slice(b), entities });
    if (caret) {
      const delta = text.length - (b - a);
      const fix = (pos) => (pos >= b ? pos + delta : Math.min(pos, a + text.length));
      if (this._hasFocus()) this.setSelectionRange(fix(caret[0]), fix(caret[1]));
      else this._saved = [fix(caret[0]), fix(caret[1])];
    } else {
      this._caretAfter(a + text.length);
    }
    this._changed();
  }

  _hasFocus() {
    return document.activeElement === this;
  }

  /** Вставка простого текста на место выделения. */
  insertText(text) {
    const [a, b] = this._current();
    this.replaceRange(a, b, text);
  }

  insertCustomEmoji(id, emoji) {
    const [a, b] = this._current();
    this.replaceRange(a, b, emoji, [{ kind: 'customEmoji', offset: 0, length: emoji.length, customEmojiId: String(id) }]);
  }

  /** Упоминание человека без username: имя-ссылка на него и пробел. */
  insertMention(a, b, name, userId) {
    this.replaceRange(a, b, `${name} `, [{ kind: 'mentionName', offset: 0, length: name.length, userId: String(userId) }]);
  }

  /** Включить/выключить вид на выделении (кнопки панели, сочетания). */
  toggle(kind, props = {}) {
    let [a, b] = this._current();
    if (a === b) return;
    this._snapshot(true);
    const doc = this.getFormatted();
    let entities = doc.entities;
    if (kind === 'clear') {
      entities = removeKind(entities, CLEARABLE, a, b);
    } else if (kind === 'textUrl') {
      entities = removeKind(entities, new Set(['textUrl']), a, b);
      if (props.url) entities.push({ kind, offset: a, length: b - a, url: props.url });
    } else if (covers(entities, kind, a, b)) {
      entities = removeKind(entities, new Set([kind]), a, b);
    } else {
      // Цитата и код — блоком: на целые строки выделения.
      if (kind === 'quote' || kind === 'pre') {
        a = doc.text.lastIndexOf('\n', a - 1) + 1;
        const nl = doc.text.indexOf('\n', b);
        b = nl < 0 ? doc.text.length : nl;
      }
      entities.push({ kind, offset: a, length: b - a, ...props });
    }
    this.setFormatted({ text: doc.text, entities });
    this.setSelectionRange(a, b);
    this._changed();
  }

  /** Виды, которые покрывают всё выделение — для подсветки кнопок. */
  activeKinds() {
    const [a, b] = this._current();
    if (a === b) return new Set();
    const { entities } = this._scan();
    return new Set(ORDER.filter((k) => covers(entities, k, a, b)));
  }

  clear() {
    this._snapshot(true);
    this.replaceChildren();
    this._saved = [0, 0];
    this._changed();
  }

  // --------------------------------------------- DOM <-> модель
  /**
   * Обход DOM: текст, сущности и карта узлов. <br> и границы блоков
   * (div/p, их создаёт браузер) — перевод строки; последний <br> —
   * служебный, текста не даёт; ZWSP — служебный, длины не имеет.
   */
  _scan() {
    let text = '';
    const entities = [];
    const map = [];
    const lastBr = this._tailBr();
    const walk = (node, isFirst) => {
      for (const child of node.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) {
          const clean = child.data.replaceAll(ZWSP, '');
          map.push({ node: child, start: text.length, type: 'text' });
          text += clean;
        } else if (child.nodeType === Node.ELEMENT_NODE) {
          if (child.classList.contains('ed-emoji')) {
            const alt = child.dataset.alt || '';
            map.push({ node: child, start: text.length, type: 'atom', length: alt.length });
            entities.push({ kind: 'customEmoji', offset: text.length, length: alt.length, customEmojiId: child.dataset.emojiId });
            text += alt;
          } else if (child.nodeName === 'BR') {
            if (child !== lastBr) {
              map.push({ node: child, start: text.length, type: 'br' });
              text += '\n';
            }
          } else {
            const block = child.nodeName === 'DIV' || child.nodeName === 'P';
            if (block && text.length && !text.endsWith('\n')) text += '\n';
            const k = kindOf(child);
            const start = text.length;
            walk(child, false);
            if (k && text.length > start) entities.push({ ...k, offset: start, length: text.length - start });
          }
        }
      }
      return isFirst;
    };
    walk(this, true);
    return { text, entities, map };
  }

  /** Служебный <br> в самом конце (за ним нет текста), или null. */
  _tailBr() {
    let n = this.lastChild;
    while (n && n.nodeType === Node.ELEMENT_NODE && n.nodeName !== 'BR' && n.lastChild
      && !n.classList.contains('ed-emoji')) n = n.lastChild;
    return n?.nodeName === 'BR' ? n : null;
  }

  /** Узлы для text[from, to) с сущностями, начиная с уровня ORDER[level]. */
  _build(text, from, to, ents, level) {
    if (from >= to) return [];
    if (level >= ORDER.length) return this._leaf(text, from, to, ents);
    const kind = ORDER[level];
    const mine = ents.filter((e) => e.kind === kind && e.offset < to && e.offset + e.length > from);
    const out = [];
    let pos = from;
    for (const e of mine) {
      const s = Math.max(e.offset, from);
      const t = Math.min(e.offset + e.length, to);
      if (s > pos) out.push(...this._build(text, pos, s, ents, level + 1));
      if (s < pos) continue;
      const wrap = elementFor(e);
      wrap.append(...this._build(text, s, t, ents, level + 1));
      out.push(wrap);
      pos = t;
    }
    if (pos < to) out.push(...this._build(text, pos, to, ents, level + 1));
    return out;
  }

  /** Текст и кастомные эмодзи. */
  _leaf(text, from, to, ents) {
    const out = [];
    const emoji = ents.filter((e) => e.kind === 'customEmoji' && e.offset >= from && e.offset + e.length <= to)
      .sort((x, y) => x.offset - y.offset);
    let pos = from;
    for (const e of emoji) {
      if (e.offset < pos) continue;
      if (e.offset > pos) out.push(document.createTextNode(text.slice(pos, e.offset)));
      out.push(this._emojiAtom(e.customEmojiId, text.slice(e.offset, e.offset + e.length)));
      pos = e.offset + e.length;
    }
    if (pos < to) out.push(document.createTextNode(text.slice(pos, to)));
    return out;
  }

  _emojiAtom(id, alt) {
    const atom = mk('span', 'ed-emoji');
    atom.contentEditable = 'false';
    atom.dataset.emojiId = String(id);
    atom.dataset.alt = alt;
    const node = customEmojiNode(id, 'emoji--text');
    atom.classList.toggle('is-pending', !node);
    atom.append(node ?? document.createTextNode(alt));
    return atom;
  }

  /** Эмодзи с запасным символом — картинкой, у кого она уже есть. */
  _refreshEmoji() {
    for (const atom of this.querySelectorAll('.ed-emoji.is-pending')) {
      const node = customEmojiNode(atom.dataset.emojiId, 'emoji--text');
      if (!node) continue;
      atom.replaceChildren(node);
      atom.classList.remove('is-pending');
    }
  }

  /** Смещение в тексте -> [узел, offset] для Range. */
  _position(offset) {
    const { map } = this._scan();
    let best = null;
    for (const m of map) {
      const len = m.type === 'text' ? m.node.data.replaceAll(ZWSP, '').length
        : m.type === 'atom' ? m.length : 1;
      if (offset < m.start) break;
      if (m.type === 'text' && offset <= m.start + len) {
        // На границе предпочтительнее следующий узел (начало),
        // чтобы набор после жирного не становился жирным, — его выберет
        // следующая итерация, если он начинается здесь же.
        best = [m.node, rawIndex(m.node.data, offset - m.start)];
        if (offset < m.start + len) return best;
      } else if (m.type !== 'text' && offset <= m.start) {
        return parentPos(m.node, false);
      } else if (m.type !== 'text' && offset === m.start + len) {
        best = parentPos(m.node, true);
      }
    }
    const tail = this._tailBr();
    return best ?? [this, this.childNodes.length - (tail && tail === this.lastChild ? 1 : 0)];
  }

  /** Выделение -> [a, b] в тексте, или null — не здесь. */
  _offsets() {
    const sel = document.getSelection();
    if (!sel?.rangeCount) return null;
    const r = sel.getRangeAt(0);
    if (!this.contains(r.startContainer)) return null;
    const at = (container, off) => {
      const probe = document.createRange();
      probe.selectNodeContents(this);
      probe.setEnd(container, off);
      // Текст до точки: тот же обход, что _scan, на копии содержимого.
      const holder = document.createElement('div');
      holder.append(probe.cloneContents());
      return scanLength(holder);
    };
    const a = at(r.startContainer, r.startOffset);
    const b = r.collapsed ? a : at(r.endContainer, r.endOffset);
    return [a, b];
  }

  _hasSelection() {
    const sel = document.getSelection();
    return Boolean(sel?.rangeCount && this.contains(sel.getRangeAt(0).startContainer));
  }

  _current() {
    return (this._hasSelection() ? this._offsets() : null) ?? this._saved ?? [this.value.length, this.value.length];
  }

  /**
   * Курсор после вставленного: если там конец оформленного элемента,
   * — в служебный ZWSP за ним, чтобы дальнейший набор был простым.
   */
  _caretAfter(offset) {
    const pos = this._position(offset);
    if (pos) {
      const [node, off] = pos;
      const inFormat = node.nodeType === Node.TEXT_NODE && off === node.data.length
        && node.parentNode !== this && kindOf(node.parentNode);
      if (inFormat) {
        let top = node.parentNode;
        while (top.parentNode !== this) top = top.parentNode;
        const tail = document.createTextNode(ZWSP);
        top.after(tail);
        const sel = document.getSelection();
        const range = document.createRange();
        range.setStart(tail, 1);
        sel.removeAllRanges();
        sel.addRange(range);
        this._saved = [offset, offset];
        return;
      }
    }
    this.setSelectionRange(offset, offset);
  }

  // --------------------------------------------- набор и отмена
  _snapshot(force) {
    const now = Date.now();
    if (!force && now - this._lastSnap < UNDO_GAP_MS) {
      this._lastSnap = now;
      return;
    }
    this._lastSnap = force ? 0 : now;
    const doc = this.getFormatted();
    const sel = this._current();
    const top = this._undo[this._undo.length - 1];
    if (top && top.doc.text === doc.text && JSON.stringify(top.doc.entities) === JSON.stringify(doc.entities)) return;
    this._undo.push({ doc, sel });
    if (this._undo.length > UNDO_MAX) this._undo.shift();
    this._redo = [];
  }

  _restore(from, to) {
    const state = from.pop();
    if (!state) return;
    to.push({ doc: this.getFormatted(), sel: this._current() });
    this.setFormatted(state.doc);
    this.setSelectionRange(...state.sel);
    this._lastSnap = 0;
    this._changed();
  }

  undo() { this._restore(this._undo, this._redo); }

  redo() {
    const state = this._redo.pop();
    if (!state) return;
    this._undo.push({ doc: this.getFormatted(), sel: this._current() });
    this.setFormatted(state.doc);
    this.setSelectionRange(...state.sel);
    this._changed();
  }

  _beforeInput(event) {
    const type = event.inputType;
    if (type === 'historyUndo') {
      event.preventDefault();
      this.undo();
      return;
    }
    if (type === 'historyRedo') {
      event.preventDefault();
      this.redo();
      return;
    }
    // Своё оформление вместо браузерного (<b> из execCommand и т.п.).
    const fmt = { formatBold: 'bold', formatItalic: 'italic', formatUnderline: 'underline', formatStrikeThrough: 'strike' }[type];
    if (fmt) {
      event.preventDefault();
      this.toggle(fmt);
      return;
    }
    if (type.startsWith('format')) {
      event.preventDefault();
      return;
    }
    // Перетаскивание и вставка — только простой текст.
    if (type === 'insertFromDrop' || type === 'insertFromPaste' || type === 'insertReplacementText') {
      const text = event.dataTransfer?.getData('text/plain') ?? event.data;
      if (type !== 'insertReplacementText') {
        event.preventDefault();
        if (text) this.insertText(text);
        return;
      }
    }
    // Перевод строки — <br>, не новый <div>.
    if (type === 'insertParagraph') {
      event.preventDefault();
      this._snapshot(true);
      document.execCommand('insertLineBreak');
      return;
    }
    this._snapshot(false);
  }

  _afterInput(event) {
    // Пустое поле — действительно пустое: иначе остаётся <br>, и
    // подсказка (:empty) не появляется.
    if (!this.textContent.replaceAll(ZWSP, '') && !this.querySelector('.ed-emoji')) {
      this.replaceChildren();
    }
    if (event.inputType === 'insertText' && event.data && /[*_~|`]$/.test(event.data)) {
      this._shortcut();
    }
  }

  /** **жирный** и т.п. сразу за курсором -> оформление (см. SHORTCUTS). */
  _shortcut() {
    const [a, b] = this._current();
    if (a !== b) return;
    const doc = this.getFormatted();
    const lineStart = doc.text.lastIndexOf('\n', a - 1) + 1;
    const before = doc.text.slice(lineStart, a);
    for (const { re, kind, mark } of SHORTCUTS) {
      const m = re.exec(before);
      if (!m) continue;
      const start = lineStart + m.index;
      const inner = m[1];
      // Внутри кода и уже такого же оформления — не трогать.
      if (doc.entities.some((e) => e.kind === 'code' && e.offset < a && e.offset + e.length > start)) return;
      this._snapshot(true);
      let ents = spliceEntities(doc.entities, a - mark, a, 0);
      ents = spliceEntities(ents, start, start + mark, 0);
      ents.push({ kind, offset: start, length: inner.length });
      const text = doc.text.slice(0, start) + inner + doc.text.slice(a);
      this.setFormatted({ text, entities: ents });
      this._caretAfter(start + inner.length);
      this._changed();
      return;
    }
  }

  _keys(event) {
    const mod = event.ctrlKey || event.metaKey;
    // Shift+Enter и Ctrl+Enter — новая строка (Enter отправляет — это
    // решает поле ввода, ui/composer.js). «Send with Ctrl+Enter» (Chat
    // settings) — наоборот: Enter и Shift+Enter — строка, Ctrl+Enter
    // отправляет.
    const byCtrl = getPref('sendByCtrlEnter');
    if (event.key === 'Enter' && (byCtrl ? !mod : (mod || event.shiftKey))) {
      event.preventDefault();
      this._snapshot(true);
      document.execCommand('insertLineBreak');
      return;
    }
    if (!mod) return;
    const key = event.key.toLowerCase();
    let kind = null;
    if (!event.shiftKey && key === 'b') kind = 'bold';
    else if (!event.shiftKey && key === 'i') kind = 'italic';
    else if (!event.shiftKey && key === 'u') kind = 'underline';
    else if (event.shiftKey && key === 'x') kind = 'strike';
    else if (event.shiftKey && key === 'm') kind = 'code';
    else if (event.shiftKey && key === 'p') kind = 'spoiler';
    else if (event.shiftKey && key === 'n') kind = 'clear';
    else if (!event.shiftKey && key === 'k') kind = 'link';
    else if (!event.shiftKey && key === 'z') {
      event.preventDefault();
      this.undo();
      return;
    } else if (key === 'y' || (event.shiftKey && key === 'z')) {
      event.preventDefault();
      this.redo();
      return;
    }
    if (!kind) return;
    event.preventDefault();
    if (kind === 'link') this.dispatchEvent(new CustomEvent('editor:link', { bubbles: true }));
    else this.toggle(kind);
  }

  _paste(event) {
    // Файлы — забота поля ввода (окно отправки / строка в статье).
    if (event.clipboardData?.files?.length) return;
    event.preventDefault();
    const text = event.clipboardData?.getData('text/plain') ?? '';
    if (text) this.insertText(text.replace(/\r\n?/g, '\n'));
  }

  /** Для слушателей input (упоминания, инлайн-боты, «печатает»). */
  _changed() {
    this.dispatchEvent(new Event('input', { bubbles: true }));
  }
}

/** Индекс в данных текстового узла с ZWSP по индексу без них. */
function rawIndex(data, clean) {
  let seen = 0;
  for (let i = 0; i < data.length; i += 1) {
    if (seen === clean) return i;
    if (data[i] !== ZWSP) seen += 1;
  }
  return data.length;
}

/** Позиция до (или после) узла — в его родителе. */
function parentPos(node, after) {
  const parent = node.parentNode;
  const idx = Array.prototype.indexOf.call(parent.childNodes, node);
  return [parent, after ? idx + 1 : idx];
}

/** Длина текста фрагмента по тем же правилам, что _scan (без служебного <br>). */
function scanLength(root) {
  let len = 0;
  let any = false;
  const walk = (node) => {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) {
        len += child.data.replaceAll(ZWSP, '').length;
        any = true;
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        if (child.classList.contains('ed-emoji')) {
          len += (child.dataset.alt || '').length;
          any = true;
        } else if (child.nodeName === 'BR') {
          len += 1;
          any = true;
        } else {
          const block = child.nodeName === 'DIV' || child.nodeName === 'P';
          if (block && any) len += 1;
          walk(child);
        }
      }
    }
  };
  walk(root);
  return len;
}

customElements.define('fptg-editor', FptgEditor);

/**
 * Сущности модели -> textEntity TDLib (для message.send/edit).
 */
export function toTdEntities(entities) {
  const type = (e) => {
    switch (e.kind) {
      case 'bold': return { '@type': 'textEntityTypeBold' };
      case 'italic': return { '@type': 'textEntityTypeItalic' };
      case 'underline': return { '@type': 'textEntityTypeUnderline' };
      case 'strike': return { '@type': 'textEntityTypeStrikethrough' };
      case 'code': return { '@type': 'textEntityTypeCode' };
      case 'spoiler': return { '@type': 'textEntityTypeSpoiler' };
      case 'quote': return { '@type': 'textEntityTypeBlockQuote' };
      case 'pre': return e.language
        ? { '@type': 'textEntityTypePreCode', language: e.language }
        : { '@type': 'textEntityTypePre' };
      case 'textUrl': return { '@type': 'textEntityTypeTextUrl', url: e.url };
      case 'mentionName': return { '@type': 'textEntityTypeMentionName', user_id: Number(e.userId) };
      case 'customEmoji': return { '@type': 'textEntityTypeCustomEmoji', custom_emoji_id: String(e.customEmojiId) };
      default: return null;
    }
  };
  return entities.map((e) => ({ e, t: type(e) })).filter((x) => x.t)
    .map(({ e, t }) => ({ '@type': 'textEntity', offset: e.offset, length: e.length, type: t }));
}

/**
 * Сущности сообщения с сервера (байтовые смещения UTF-8, виды
 * util/entities.js) -> модель поля (UTF-16) — для правки.
 */
export function fromMessageEntities(text, list = []) {
  // Байтовая позиция -> индекс UTF-16, по кодовым точкам.
  const enc = new TextEncoder();
  const map = new Map([[0, 0]]);
  let bytes = 0;
  let units = 0;
  for (const ch of text) {
    bytes += enc.encode(ch).length;
    units += ch.length;
    map.set(bytes, units);
  }
  const at = (b) => map.get(b) ?? units;
  const kinds = {
    bold: 'bold', italic: 'italic', underline: 'underline', strike: 'strike', code: 'code',
    pre: 'pre', spoiler: 'spoiler', quote: 'quote', textUrl: 'textUrl',
    mentionName: 'mentionName', customEmoji: 'customEmoji',
  };
  const out = [];
  for (const e of list) {
    const kind = kinds[e.kind];
    if (!kind) continue;
    const s = at(e.start);
    const t = at(e.start + e.len);
    if (t <= s) continue;
    out.push({
      kind, offset: s, length: t - s,
      url: e.url, userId: e.userId, customEmojiId: e.customEmojiId, language: e.language,
    });
  }
  return out;
}
