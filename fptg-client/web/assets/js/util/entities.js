import { el } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { customEmojiNode } from './emoji.js';
import { icon } from './icons.js';
import { highlight } from './highlight.js';
import { copyText, copyNode } from './clipboard.js';

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
// on (see the "eaten text / wrong icon" entry in the development log). Getting it
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

  // A code block is a block for the same reason a quote is: it has a
  // header of its own and it interrupts the line. `code` joins them
  // only when it IS the whole message - that is the Mono button used
  // on everything - while a backticked word inside a sentence stays
  // inline, where it belongs.
  const isBlock = (e) => e.kind === 'quote' || e.kind === 'pre'
    || (e.kind === 'code' && e.start === 0 && e.start + e.len >= bytes.length);

  const blocks = entities.filter(isBlock).sort((a, b) => a.start - b.start);
  const inline = entities.filter((e) => !isBlock(e));

  // A blockquote is a block, not a span: it gets its own band with a
  // bar down the left, and the text around it stays where it was. So
  // the text is cut into top-level blocks first, and the inline pass
  // runs inside each one.
  let cursor = 0;
  for (const block of blocks) {
    if (block.start > cursor) {
      appendInline(frag, bytes, cursor, block.start, inline);
    }
    if (block.kind === 'quote') {
      const band = el('blockquote', { class: 'message__quote' });
      appendInline(band, bytes, block.start, block.start + block.len, inline);
      frag.append(band);
    } else {
      frag.append(codeBlock(bytes, block, inline));
    }
    cursor = block.start + block.len;
  }
  if (cursor < bytes.length) {
    appendInline(frag, bytes, cursor, bytes.length, inline);
  }
  return frag;
}

/**
 * A code block with the header the official client gives it: what the
 * thing is on the left - the language when TDLib named one, the action
 * otherwise - and a button that puts the code on the clipboard.
 *
 * The label doubles as the button's own words on purpose: with no
 * language there is nothing else to call the block, and "copy" is what
 * the original says there too.
 */
function codeBlock(bytes, entity, inline) {
  const body = el('pre', { class: 'code__body' });
  appendInline(body, bytes, entity.start, entity.start + entity.len, inline);

  // Highlighting arrives later than the block, and may never arrive at
  // all (unknown language, a file that would not load). The plain
  // block is already on screen by then and is a complete answer on its
  // own, so this only ever replaces what is there - and only if the
  // node is still in the document.
  if (entity.language) {
    highlight(body.textContent, entity.language).then((nodes) => {
      if (!nodes || !body.isConnected) return;
      body.replaceChildren(nodes);
      body.classList.add('is-highlighted');
    });
  }

  const label = el('span', {
    class: 'code__label',
    textContent: entity.language || 'copy',
  });
  const button = el('button', {
    class: 'code__copy',
    type: 'button',
    title: 'Copy this code',
    onclick: () => copy(body, label, entity.language),
  }, icon('copy'));

  return el('div', { class: 'code' },
    el('div', { class: 'code__head' }, label, button),
    body);
}

/**
 * Two routes, because the modern one is not always open: measured in
 * the embedded browser this project is tested in, writeText answers
 * "NotAllowedError: Write permission denied" with the document
 * focused and a real click behind it, while the old selection-based
 * command returns true on the same page. So: ask nicely, then fall
 * back, and only say "could not copy" when both refuse - silence
 * would look exactly like success.
 */
async function copy(body, label, language) {
  const back = language || 'copy';
  const ok = await copyText(body.textContent) || copyNode(body);
  label.textContent = ok ? 'copied' : 'could not copy';
  setTimeout(() => { label.textContent = back; }, 1200);
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
    target.append(wrap(piece, covering, s, t));
  }
}

function revealSpoiler(event) {
  const span = event.currentTarget;
  if (span.classList.contains('is-revealed')) return;
  // The first click only reveals — it does not press a link inside.
  event.preventDefault();
  event.stopPropagation();
  const scope = span.closest('.message') ?? span.parentElement;
  for (const part of scope.querySelectorAll(`.spoiler[data-spoiler="${span.dataset.spoiler}"]`)) {
    part.classList.add('is-revealed');
  }
}

function wrap(piece, covering, from, to) {
  // A custom emoji REPLACES its text rather than decorating it: the
  // characters underneath are the plain-emoji fallback Telegram sends
  // with it, and they are what stays on screen until the file arrives
  // (customEmojiNode answers null until then).
  //
  // Only when this piece is the whole span: an entity split by an
  // overlapping one would otherwise draw the emoji once per fragment.
  const custom = covering.find(
    (e) => e.kind === 'customEmoji' && e.start === from && e.start + e.len === to,
  );
  if (custom) {
    const node = customEmojiNode(custom.customEmojiId, 'emoji--text');
    if (node) return node;
  }

  // Innermost first, so the link ends up outermost and clicking
  // anywhere inside a styled link still hits the anchor.
  let node = document.createTextNode(piece);

  for (const e of covering) {
    const tag = INLINE_TAG[e.kind];
    if (tag) node = el(tag, {}, node);
  }

  // A spoiler: hidden until a click; one entity may have several pieces
  // (other entities cut it) — they all open together.
  const spoiler = covering.find((e) => e.kind === 'spoiler');
  if (spoiler) {
    node = el('span', {
      class: 'spoiler',
      dataset: { spoiler: String(spoiler.start) },
      onclick: revealSpoiler,
    }, node);
  }

  const link = covering.find((e) => e.kind === 'url' || e.kind === 'textUrl');
  if (link) {
    const href = link.kind === 'textUrl' ? link.url : piece;
    node = el('a', {
      href: safeHref(href),
      target: '_blank',
      rel: 'noopener noreferrer',
    }, node);
    return node;
  }

  // Mentions. @username — a t.me link: ui/links.js intercepts it and opens
  // the person or chat right here. Without a username (mentionName) — the
  // private chat with the person by id (ui:open-contact).
  const mention = covering.find((e) => e.kind === 'mention' || e.kind === 'mentionName');
  if (mention?.kind === 'mention' && /^@?[A-Za-z0-9_]{3,32}$/.test(piece)) {
    node = el('a', {
      class: 'mention',
      href: `https://t.me/${piece.replace(/^@/, '')}`,
      target: '_blank',
      rel: 'noopener noreferrer',
    }, node);
  } else if (mention?.kind === 'mentionName' && mention.userId) {
    node = el('a', {
      class: 'mention',
      href: '#',
      onclick: (event) => {
        event.preventDefault();
        emit('ui:open-contact', { userId: mention.userId });
      },
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
export function safeHref(raw) {
  const value = String(raw ?? '').trim();
  if (/^(https?:|tg:|mailto:)/i.test(value)) return value;
  if (/^[\w.-]+\.[a-z]{2,}(\/|$)/i.test(value)) return `https://${value}`;
  return '#';
}
