import { customEmojiNode } from '../util/emoji.js';
import { getPref } from '../util/prefs.js';

// The message input field: a contenteditable that shows the result, not
// the markup — bold as bold, a custom emoji as a picture.
//
// THE MODEL is text and entities (as in Telegram): { text, entities }, where
// an entity is { kind, offset, length, ...kind fields }, offsets in UTF-16
// (TDLib counts in them too, and it is the JS string length). The DOM is
// only its view: any formatting change goes through the model
// (getFormatted -> edit -> setFormatted), while typing is ordinary, the
// browser's; the DOM is read back into the model (scan) when it is needed.
//
// Outside, the element pretends to be a textarea: value, placeholder,
// disabled, selectionStart/End, setSelectionRange — mention suggestions,
// inline bots and insertions rely on that (ui/mentions.js, ui/bots.js).
//
// Entity kinds: bold, italic, underline, strike, code, pre, spoiler,
// quote, textUrl {url}, mentionName {userId}, customEmoji {customEmojiId}.
//
// Typing shortcuts — as in Telegram Desktop: **bold**, __italic__,
// ~~strikethrough~~, ||spoiler||, `mono`; single *, _, ~ are just
// characters. Key combinations: Ctrl+B/I/U, Ctrl+Shift+X (strikethrough),
// Ctrl+Shift+M (mono), Ctrl+Shift+P (spoiler), Ctrl+K (link),
// Ctrl+Shift+N (clear formatting).

const ZWSP = '​';
// The nesting order of elements: outer ones first.
const ORDER = ['quote', 'pre', 'textUrl', 'mentionName', 'bold', 'italic',
  'underline', 'strike', 'spoiler', 'code'];
const INLINE_KINDS = new Set(['bold', 'italic', 'underline', 'strike', 'spoiler', 'code']);
// What "Clear" removes: everything except what carries meaning, not looks.
const CLEARABLE = new Set([...INLINE_KINDS, 'pre', 'quote', 'textUrl']);
// The pause after which typing is a new undo step.
const UNDO_GAP_MS = 800;
const UNDO_MAX = 100;

const SHORTCUTS = [
  { re: /\*\*(\S(?:[^\n]*?\S)?)\*\*$/, kind: 'bold', mark: 2 },
  { re: /__(\S(?:[^\n]*?\S)?)__$/, kind: 'italic', mark: 2 },
  { re: /~~(\S(?:[^\n]*?\S)?)~~$/, kind: 'strike', mark: 2 },
  { re: /\|\|(\S(?:[^\n]*?\S)?)\|\|$/, kind: 'spoiler', mark: 2 },
  { re: /(?<!`)`([^`\n]+)`$/, kind: 'code', mark: 1 },
];

/** One entity — one element (kind and fields). */
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

/** A DOM element -> the entity kind (or null — just a wrapper). */
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

/** Sorting and merging adjacent/overlapping entities of one kind. */
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
 * Cut [a, b) and insert insLen characters: entities shift and get trimmed;
 * an insertion inside an entity continues it. A custom emoji touched by the
 * edit disappears whole (it is atomic).
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
      // touched — disappears
    } else if (s < a && t > b) {
      out.push({ ...e, length: e.length + delta });
    } else {
      if (s < a) out.push({ ...e, length: a - s });
      if (t > b) out.push({ ...e, offset: b + delta, length: t - b });
    }
  }
  return normalizeEntities(out);
}

/** Whether kind is present on the whole [a, b). */
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

/** Remove kind from [a, b) (parts of entities outside the range stay). */
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
    this._saved = null;      // the last selection while focus is not here
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
    // An emoji file finished downloading — the fallback character becomes a picture.
    document.addEventListener('custom-emoji:ready', () => this._refreshEmoji());
  }

  // --------------------------------------------- like a textarea
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

  // --------------------------------------------- the model
  /** Text and entities (UTF-16 offsets). */
  getFormatted() {
    const { text, entities } = this._scan();
    return { text, entities: normalizeEntities(entities) };
  }

  /** Replace the content with the model; the selection goes to the end. */
  setFormatted({ text, entities = [] }) {
    const ents = normalizeEntities(entities.filter((e) => e.offset >= 0
      && e.offset + e.length <= text.length));
    this.replaceChildren(...this._build(text, 0, text.length, ents, 0));
    // An empty last line is visible only with a <br> after it.
    if (text.endsWith('\n')) this.append(document.createElement('br'));
  }

  /**
   * Replace [a, b) with text (with entities inside it, from 0) and put the
   * caret after it. keepCaret — the caret stays where it was (shifted by
   * the length difference if it is past the edit): a replacement the person
   * did not make themselves — for example, a file that finished downloading.
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

  /** Insert plain text in place of the selection. */
  insertText(text) {
    const [a, b] = this._current();
    this.replaceRange(a, b, text);
  }

  insertCustomEmoji(id, emoji) {
    const [a, b] = this._current();
    this.replaceRange(a, b, emoji, [{ kind: 'customEmoji', offset: 0, length: emoji.length, customEmojiId: String(id) }]);
  }

  /** A mention of a person without a username: the name linking to them and a space. */
  insertMention(a, b, name, userId) {
    this.replaceRange(a, b, `${name} `, [{ kind: 'mentionName', offset: 0, length: name.length, userId: String(userId) }]);
  }

  /** Turn a kind on/off on the selection (panel buttons, key combinations). */
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
      // A quote and code — as a block: on the selection's whole lines.
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

  /** Kinds covering the whole selection — for highlighting the buttons. */
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

  // --------------------------------------------- DOM <-> model
  /**
   * A DOM walk: text, entities and the node map. <br> and block boundaries
   * (div/p, the browser creates them) are a line break; the last <br> is a
   * service one and gives no text; ZWSP is a service one and has no length.
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

  /** The service <br> at the very end (no text after it), or null. */
  _tailBr() {
    let n = this.lastChild;
    while (n && n.nodeType === Node.ELEMENT_NODE && n.nodeName !== 'BR' && n.lastChild
      && !n.classList.contains('ed-emoji')) n = n.lastChild;
    return n?.nodeName === 'BR' ? n : null;
  }

  /** Nodes for text[from, to) with entities, starting at the level ORDER[level]. */
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

  /** Text and custom emoji. */
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

  /** Emoji with a fallback character — as a picture, for those that have it already. */
  _refreshEmoji() {
    for (const atom of this.querySelectorAll('.ed-emoji.is-pending')) {
      const node = customEmojiNode(atom.dataset.emojiId, 'emoji--text');
      if (!node) continue;
      atom.replaceChildren(node);
      atom.classList.remove('is-pending');
    }
  }

  /** An offset in the text -> [node, offset] for a Range. */
  _position(offset) {
    const { map } = this._scan();
    let best = null;
    for (const m of map) {
      const len = m.type === 'text' ? m.node.data.replaceAll(ZWSP, '').length
        : m.type === 'atom' ? m.length : 1;
      if (offset < m.start) break;
      if (m.type === 'text' && offset <= m.start + len) {
        // At a boundary the next node (its start) is preferable, so that
        // typing after bold does not become bold — the next iteration picks
        // it if it starts right here.
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

  /** The selection -> [a, b] in the text, or null — not here. */
  _offsets() {
    const sel = document.getSelection();
    if (!sel?.rangeCount) return null;
    const r = sel.getRangeAt(0);
    if (!this.contains(r.startContainer)) return null;
    const at = (container, off) => {
      const probe = document.createRange();
      probe.selectNodeContents(this);
      probe.setEnd(container, off);
      // The text before the point: the same walk as _scan, on a copy of the content.
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
   * The caret after the inserted text: if the end of a formatted element is
   * there — into the service ZWSP after it, so further typing is plain.
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

  // --------------------------------------------- typing and undo
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
    // Our own formatting instead of the browser's (<b> from execCommand and the like).
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
    // Dragging and pasting — plain text only.
    if (type === 'insertFromDrop' || type === 'insertFromPaste' || type === 'insertReplacementText') {
      const text = event.dataTransfer?.getData('text/plain') ?? event.data;
      if (type !== 'insertReplacementText') {
        event.preventDefault();
        if (text) this.insertText(text);
        return;
      }
    }
    // A line break is a <br>, not a new <div>.
    if (type === 'insertParagraph') {
      event.preventDefault();
      this._snapshot(true);
      document.execCommand('insertLineBreak');
      return;
    }
    this._snapshot(false);
  }

  _afterInput(event) {
    // An empty field is really empty: otherwise a <br> stays, and the
    // placeholder (:empty) does not appear.
    if (!this.textContent.replaceAll(ZWSP, '') && !this.querySelector('.ed-emoji')) {
      this.replaceChildren();
    }
    if (event.inputType === 'insertText' && event.data && /[*_~|`]$/.test(event.data)) {
      this._shortcut();
    }
  }

  /** **bold** and the like right before the caret -> formatting (see SHORTCUTS). */
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
      // Inside code and already the same formatting — leave alone.
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
    // Shift+Enter and Ctrl+Enter — a new line (Enter sends — the input field
    // decides that, ui/composer.js). "Send with Ctrl+Enter" (Chat settings)
    // — the other way round: Enter and Shift+Enter — a line, Ctrl+Enter
    // sends.
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
    // Files are the input field's business (the send window / a row in an article).
    if (event.clipboardData?.files?.length) return;
    event.preventDefault();
    const text = event.clipboardData?.getData('text/plain') ?? '';
    if (text) this.insertText(text.replace(/\r\n?/g, '\n'));
  }

  /** For input listeners (mentions, inline bots, "typing"). */
  _changed() {
    this.dispatchEvent(new Event('input', { bubbles: true }));
  }
}

/** An index in the data of a text node with ZWSP by the index without them. */
function rawIndex(data, clean) {
  let seen = 0;
  for (let i = 0; i < data.length; i += 1) {
    if (seen === clean) return i;
    if (data[i] !== ZWSP) seen += 1;
  }
  return data.length;
}

/** The position before (or after) a node — in its parent. */
function parentPos(node, after) {
  const parent = node.parentNode;
  const idx = Array.prototype.indexOf.call(parent.childNodes, node);
  return [parent, after ? idx + 1 : idx];
}

/** The fragment's text length by the same rules as _scan (without the service <br>). */
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
 * Model entities -> TDLib textEntity (for message.send/edit).
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
 * A message's entities from the server (UTF-8 byte offsets, the kinds of
 * util/entities.js) -> the field's model (UTF-16) — for editing.
 */
export function fromMessageEntities(text, list = []) {
  // A byte position -> a UTF-16 index, by code points.
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
