import { el } from '../core/dom.js';

// Turning a message's text plus its entity ranges into DOM.
//
// THE ONE THING THAT MATTERS HERE: the offsets are BYTE offsets into
// UTF-8. That is the convention the whole Pascal side uses for
// utf8string (tdmessages.TMsgEntity says so outright), and TDLib's own
// UTF-16 offsets were already converted once, on the way in. JavaScript
// indexes strings in UTF-16 code units, so slicing with these numbers
// directly puts every entity in the wrong place the moment the text
// stops being pure ASCII - which, for this project's traffic, is most
// of the time. So: encode once, cut the bytes, decode each piece.
//
// This is the same class of bug the native side spent a whole session
// on (see the "eaten text / wrong icon" entry in docs/journal/). Getting it
// wrong is not subtle in its consequences, only in its appearance.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// Entities that wrap a run of text inline.
const INLINE_TAG = {
  bold: 'b',
  italic: 'i',
  underline: 'u',
  strike: 's',
  code: 'code',
  pre: 'pre',
};

/**
 * Renders into a container element.
 *
 * `onQuoteClick` is optional and only used for the blockquote band, so
 * the caller can decide whether a quote is interactive.
 */
export function renderRichText(text, entities = []) {
  const frag = document.createDocumentFragment();
  if (!text) return frag;

  const bytes = encoder.encode(text);
  const quotes = entities
    .filter((e) => e.kind === 'quote')
    .sort((a, b) => a.start - b.start);
  const inline = entities.filter((e) => e.kind !== 'quote');

  // A blockquote is a block, not a span: it gets its own band with a
  // bar down the left, and the text around it stays where it was. So
  // the text is cut into top-level blocks first, and the inline pass
  // runs inside each one.
  let cursor = 0;
  for (const quote of quotes) {
    if (quote.start > cursor) {
      appendInline(frag, bytes, cursor, quote.start, inline);
    }
    const band = el('blockquote', { class: 'message__quote' });
    appendInline(band, bytes, quote.start, quote.start + quote.len, inline);
    frag.append(band);
    cursor = quote.start + quote.len;
  }
  if (cursor < bytes.length) {
    appendInline(frag, bytes, cursor, bytes.length, inline);
  }
  return frag;
}

/**
 * Cuts [from, to) into the smallest pieces over which the set of
 * covering entities does not change, then wraps each piece.
 *
 * Boundaries rather than a nesting walk because entities are allowed
 * to overlap partially (bold across the tail of a link, say). Splitting
 * at every edge means each piece has one flat set of styles and nothing
 * has to be reconciled.
 */
function appendInline(target, bytes, from, to, entities) {
  const edges = new Set([from, to]);
  for (const e of entities) {
    const s = Math.max(e.start, from);
    const t = Math.min(e.start + e.len, to);
    if (t > s) {
      edges.add(s);
      edges.add(t);
    }
  }
  const points = [...edges].sort((a, b) => a - b);

  for (let i = 0; i < points.length - 1; i += 1) {
    const s = points[i];
    const t = points[i + 1];
    if (t <= s) continue;

    const piece = decoder.decode(bytes.subarray(s, t));
    const covering = entities.filter(
      (e) => e.start <= s && e.start + e.len >= t,
    );
    target.append(wrap(piece, covering));
  }
}

function wrap(piece, covering) {
  // Innermost first, so the link ends up outermost and clicking
  // anywhere inside a styled link still hits the anchor.
  let node = document.createTextNode(piece);

  for (const e of covering) {
    const tag = INLINE_TAG[e.kind];
    if (tag) node = el(tag, {}, node);
  }

  const link = covering.find((e) => e.kind === 'url' || e.kind === 'textUrl');
  if (link) {
    const href = link.kind === 'textUrl' ? link.url : piece;
    node = el('a', {
      href: safeHref(href),
      target: '_blank',
      rel: 'noopener noreferrer',
    }, node);
  }
  return node;
}

/**
 * Message text is written by strangers, and an href is one of the few
 * places where a string alone can execute something (javascript:, and
 * data: for the same reason). Anything that is not plainly a web or
 * telegram link is rendered as an unclickable span instead of being
 * guessed at.
 */
function safeHref(raw) {
  const value = String(raw ?? '').trim();
  if (/^(https?:|tg:|mailto:)/i.test(value)) return value;
  if (/^[\w.-]+\.[a-z]{2,}(\/|$)/i.test(value)) return `https://${value}`;
  return '#';
}
