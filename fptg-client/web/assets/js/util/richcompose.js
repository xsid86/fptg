// A rich message from the input field -> InputPageBlock blocks for
// message.sendRich (td_api.tl: inputRichMessage, richMessageSourceBlocks).
//
// TDLib's Markdown/HTML sources are for bots only, so the page assembles
// the blocks. The input is the field's model (ui/editor.js): text and
// entities. Inline formatting (bold, a link, a custom emoji…) — entities;
// blocks — the start of a line, the familiar Markdown:
//
//   # Heading … ###### (size 1–6)
//   - item / * item / 1. item / - [ ] task / - [x] done
//     (nesting — by an indent of two spaces or more)
//   > quote (consecutive lines; the last "> — Author" is the caption)
//   ```language … ```      code (or lines formatted as code whole)
//   $$ … $$                a formula (LaTeX)
//   ---                    a divider
//   | a | b |              a table; the row |---|:-:|--:| — header and alignment
//   +++ Heading … +++      a collapsible block (+++! — open)
//   ![caption](photo:id)   a photo, video (video:), GIF (gif:), audio (audio:),
//                          file (file:) — the POST /upload id; the input field
//                          inserts the line when a file is attached in Rich
//                          mode. Several consecutive lines — a collage.
//   [[Text|https://…]]     a link button; [[Text|copy:text]] — copies the
//                          text; the third field is the style: primary,
//                          danger, success, link. A line of buttons only — a
//                          row of buttons, inside a paragraph — a button in the text.
//
// In the text there is also $$formula$$. A quote and code formatted by the
// buttons on whole lines are blocks too.
//
// An ordinary user can only have link, "user" and "copy text" buttons
// (td_api.tl, inlineButton).

const plain = (text) => ({ '@type': 'richTextPlain', text });

// Info about an uploaded file (duration, size, the video thumbnail) — for
// the duration of one composeRich, see its parameter.
let mediaInfo = () => null;

const MEDIA_RE = /^!\[([^\]]*)\]\((photo|video|gif|audio|file|uploading):([^)\s]+)\)$/;
const upload = (id) => ({ '@type': 'inputFileUpload', id });

// ------------------------------------------------------------ lines
// A line is { text, ents, block }: entities with offsets from the start of
// the line; block — { pre, quote }: the ids of block entities covering the
// whole line.

/** The field's model -> lines. */
function toLines(doc) {
  const text = String(doc?.text ?? '').replace(/\r\n?/g, '\n');
  const all = (doc?.entities ?? []).map((e, id) => ({ ...e, id }));
  const out = [];
  let ls = 0;
  for (const part of text.split('\n')) {
    const le = ls + part.length;
    const ents = [];
    const block = {};
    for (const e of all) {
      const s = e.offset;
      const t = e.offset + e.length;
      if ((e.kind === 'pre' || e.kind === 'quote') && s <= ls && t >= le && (le > ls || t > ls)) {
        block[e.kind] = e;
        continue;
      }
      const a = Math.max(s, ls);
      const b = Math.min(t, le);
      if (b > a) ents.push({ ...e, offset: a - ls, length: b - a });
    }
    out.push({ text: part, ents, block });
    ls = le + 1;
  }
  return out;
}

/** A piece of a line [from, to). */
function slice(line, from, to = line.text.length) {
  const ents = [];
  for (const e of line.ents) {
    const a = Math.max(e.offset, from);
    const b = Math.min(e.offset + e.length, to);
    if (b > a) ents.push({ ...e, offset: a - from, length: b - a });
  }
  return { text: line.text.slice(from, to), ents, block: line.block };
}

/** Without spaces at the edges. */
function trimmed(line) {
  const lead = /^\s*/.exec(line.text)[0].length;
  const tail = /\s*$/.exec(line.text)[0].length;
  return slice(line, lead, Math.max(lead, line.text.length - tail));
}

const indentOf = (line) => /^\s*/.exec(line.text)[0].length;

// ------------------------------------------------------------ inline

/** RichText nodes -> one RichText (adjacent plain ones are merged). */
function joinTexts(nodes) {
  const out = [];
  for (const n of nodes) {
    const prev = out[out.length - 1];
    if (n['@type'] === 'richTextPlain' && prev?.['@type'] === 'richTextPlain') {
      out[out.length - 1] = plain(prev.text + n.text);
    } else if (n['@type'] !== 'richTextPlain' || n.text !== '') {
      out.push(n);
    }
  }
  if (!out.length) return plain('');
  if (out.length === 1) return out[0];
  return { '@type': 'richTexts', texts: out };
}

const BUTTON_STYLES = new Set(['default', 'primary', 'danger', 'success', 'link']);

/** "Text|target|style" -> inlineButton, or null — not a button. */
function parseButton(body) {
  const parts = body.split('|').map((p) => p.trim());
  if (parts.length < 2 || !parts[0] || !parts[1]) return null;
  const [label, target, styleName = 'default'] = parts;
  let type;
  if (/^copy:/i.test(target)) {
    type = { '@type': 'inlineKeyboardButtonTypeCopyText', text: target.slice(5) };
  } else if (/^(https?:\/\/|tg:\/\/)/i.test(target)) {
    type = { '@type': 'inlineKeyboardButtonTypeUrl', url: target };
  } else if (/^[\w.-]+\.[a-z]{2,}(\/|$)/i.test(target)) {
    type = { '@type': 'inlineKeyboardButtonTypeUrl', url: `https://${target}` };
  } else {
    return null;
  }
  const style = BUTTON_STYLES.has(styleName.toLowerCase()) ? styleName.toLowerCase() : 'default';
  const cap = style[0].toUpperCase() + style.slice(1);
  return {
    '@type': 'inlineButton',
    text: plain(label),
    style: { '@type': `buttonStyle${cap}` },
    type,
  };
}

/** A plain piece of text: [[…]] buttons and $$…$$ formulas inside. */
function plainNodes(str) {
  const out = [];
  const re = /\[\[([^\]]+)\]\]|\$\$([^$]+)\$\$/g;
  let pos = 0;
  for (const m of str.matchAll(re)) {
    let node = null;
    if (m[1] !== undefined) {
      const button = parseButton(m[1]);
      if (button) node = { '@type': 'richTextButton', button };
    } else {
      node = { '@type': 'richTextMathematicalExpression', expression: m[2].trim() };
    }
    if (!node) continue;
    if (m.index > pos) out.push(plain(str.slice(pos, m.index)));
    out.push(node);
    pos = m.index + m[0].length;
  }
  if (pos < str.length) out.push(plain(str.slice(pos)));
  return out;
}

// Formatting nesting: inner ones first.
const WRAP_ORDER = ['code', 'pre', 'spoiler', 'strike', 'underline', 'italic', 'bold', 'mentionName', 'textUrl'];

function wrapRich(node, e) {
  switch (e.kind) {
    case 'code':
    case 'pre': return { '@type': 'richTextFixed', text: node };
    case 'spoiler': return { '@type': 'richTextSpoiler', text: node };
    case 'strike': return { '@type': 'richTextStrikethrough', text: node };
    case 'underline': return { '@type': 'richTextUnderline', text: node };
    case 'italic': return { '@type': 'richTextItalic', text: node };
    case 'bold': return { '@type': 'richTextBold', text: node };
    case 'mentionName': return { '@type': 'richTextMentionName', text: node, user_id: Number(e.userId) };
    case 'textUrl': return { '@type': 'richTextUrl', text: node, url: e.url, is_cached: false };
    default: return node;
  }
}

/** A line -> RichText by its entities. */
function rich(line) {
  const { text, ents } = line;
  const cuts = new Set([0, text.length]);
  for (const e of ents) {
    cuts.add(e.offset);
    cuts.add(e.offset + e.length);
  }
  const points = [...cuts].filter((p) => p >= 0 && p <= text.length).sort((x, y) => x - y);
  const nodes = [];
  for (let i = 0; i < points.length - 1; i += 1) {
    const s = points[i];
    const t = points[i + 1];
    if (t <= s) continue;
    const covering = ents.filter((e) => e.offset <= s && e.offset + e.length >= t);
    const emoji = covering.find((e) => e.kind === 'customEmoji');
    let node;
    if (emoji) {
      // A custom emoji replaces its text (the fallback ordinary emoji).
      if (s !== emoji.offset) continue;
      node = {
        '@type': 'richTextCustomEmoji',
        custom_emoji_id: String(emoji.customEmojiId),
        alternative_text: text.slice(emoji.offset, emoji.offset + emoji.length),
      };
    } else {
      node = joinTexts(plainNodes(text.slice(s, t)));
    }
    for (const kind of WRAP_ORDER) {
      const e = covering.find((x) => x.kind === kind);
      if (e) node = wrapRich(node, e);
    }
    nodes.push(node);
  }
  return joinTexts(nodes);
}

/** Several lines -> one RichText joined with line breaks. */
function richLines(lines) {
  const parts = [];
  lines.forEach((l, i) => {
    if (i) parts.push(plain('\n'));
    parts.push(rich(l));
  });
  return joinTexts(parts);
}

// ------------------------------------------------------------ media

/** A media line -> an InputPageBlock block. */
function mediaBlock(kind, id, capLine) {
  if (kind === 'uploading') throw new Error('Wait until the files finish uploading');
  const caption = capLine.text.trim()
    ? { '@type': 'pageBlockCaption', text: rich(trimmed(capLine)), credit: plain('') }
    : null;
  const info = mediaInfo(id) ?? {};
  const file = upload(id);
  switch (kind) {
    case 'photo':
      return {
        '@type': 'inputPageBlockPhoto',
        photo: { '@type': 'inputPhoto', photo: file, thumbnail: null, video: null,
          added_sticker_file_ids: [], width: 0, height: 0 },
        caption, has_spoiler: false,
      };
    case 'video':
      return {
        '@type': 'inputPageBlockVideo',
        video: {
          '@type': 'inputVideo', video: file,
          thumbnail: info.thumb ? { '@type': 'inputThumbnail', thumbnail: upload(info.thumb),
            width: info.tw ?? 0, height: info.th ?? 0 } : null,
          cover: null, start_timestamp: 0, added_sticker_file_ids: [],
          duration: info.duration ?? 0, width: info.w ?? 0, height: info.h ?? 0,
          supports_streaming: true,
        },
        caption, has_spoiler: false,
      };
    case 'gif':
      return {
        '@type': 'inputPageBlockAnimation',
        animation: { '@type': 'inputAnimation', animation: file, thumbnail: null,
          added_sticker_file_ids: [], duration: 0, width: 0, height: 0 },
        caption, has_spoiler: false,
      };
    case 'audio':
      return {
        '@type': 'inputPageBlockAudio',
        audio: { '@type': 'inputAudio', audio: file, album_cover_thumbnail: null,
          duration: 0, title: '', performer: '' },
        caption,
      };
    default:
      return {
        '@type': 'inputPageBlockDocument',
        document: { '@type': 'inputDocument', document: file, thumbnail: null,
          disable_content_type_detection: false },
        caption,
      };
  }
}

/** A media line -> a block, or null — not media. */
function mediaLine(line) {
  const t = trimmed(line);
  const m = MEDIA_RE.exec(t.text);
  if (!m) return null;
  return mediaBlock(m[2], m[3], slice(t, 2, 2 + m[1].length));
}

// ------------------------------------------------------------ blocks

const LIST_RE = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const ALIGN = {
  left: { '@type': 'pageBlockHorizontalAlignmentLeft' },
  center: { '@type': 'pageBlockHorizontalAlignmentCenter' },
  right: { '@type': 'pageBlockHorizontalAlignmentRight' },
};

// A numbered and a bulleted list in a row — two lists, not one.
const isNumbered = (text) => /^\d/.test(LIST_RE.exec(text)?.[2] ?? '');
const sameKind = (a, b) => isNumbered(a) === isNumbered(b);

/** A line of [[…]] buttons only -> their list, otherwise null. */
function buttonRow(text) {
  const t = text.trim();
  if (!/^(\[\[[^\]]+\]\]\s*)+$/.test(t)) return null;
  const out = [];
  for (const m of t.matchAll(/\[\[([^\]]+)\]\]/g)) {
    const b = parseButton(m[1]);
    if (!b) return null;
    out.push(b);
  }
  return out;
}

/** The cells of a table row: the pieces between "|", without the edges. */
function splitRow(line) {
  const t = trimmed(line);
  const bars = [];
  for (let i = 0; i < t.text.length; i += 1) {
    if (t.text[i] === '|' && t.text[i - 1] !== '\\') bars.push(i);
  }
  if (bars[0] !== 0) bars.unshift(-1);
  if (bars[bars.length - 1] !== t.text.length - 1) bars.push(t.text.length);
  const cells = [];
  for (let i = 0; i < bars.length - 1; i += 1) cells.push(trimmed(slice(t, bars[i] + 1, bars[i + 1])));
  return cells;
}

function tableBlock(lines) {
  let rows = lines.map(splitRow);
  let aligns = [];
  let headerRows = 0;
  const isSep = (r) => r.every((c) => /^:?-{1,}:?$/.test(c.text));
  if (rows.length > 1 && isSep(rows[1])) {
    aligns = rows[1].map((c) => (c.text.startsWith(':') && c.text.endsWith(':') ? 'center'
      : c.text.endsWith(':') ? 'right' : 'left'));
    rows = [rows[0], ...rows.slice(2)];
    headerRows = 1;
  }
  return {
    '@type': 'inputPageBlockTable',
    caption: plain(''),
    cells: rows.map((r, ri) => r.map((c, ci) => ({
      '@type': 'pageBlockTableCell',
      text: rich(c),
      is_header: ri < headerRows,
      colspan: 1,
      rowspan: 1,
      align: ALIGN[aligns[ci] ?? 'left'],
      valign: { '@type': 'pageBlockVerticalAlignmentTop' },
    }))),
    is_bordered: true,
    is_striped: false,
    is_compact: false,
  };
}

function dedent(lines) {
  const ind = Math.min(...lines.filter((l) => l.text.trim()).map(indentOf));
  const cut = Number.isFinite(ind) ? ind : 0;
  return lines.map((l) => slice(l, Math.min(cut, indentOf(l))));
}

function listBlock(lines) {
  // An item is a marker line at the base indent; everything deeper is its
  // continuation (a paragraph or a nested list).
  const base = indentOf(lines[0]);
  const items = [];
  let cur = null;
  for (const line of lines) {
    const m = LIST_RE.exec(line.text);
    if (m && indentOf(line) <= base) {
      cur = { marker: m[2], first: slice(line, line.text.length - m[3].length), rest: [] };
      items.push(cur);
    } else if (cur) {
      cur.rest.push(line);
    }
  }
  return {
    '@type': 'inputPageBlockList',
    items: items.map((it) => {
      let first = it.first;
      let hasBox = false;
      let checked = false;
      const box = /^\[( |x|X)\]\s+/.exec(first.text);
      if (box) {
        hasBox = true;
        checked = box[1] !== ' ';
        first = slice(first, box[0].length);
      }
      const num = /^\d+/.exec(it.marker);
      const inner = it.rest.length ? parseBlocks(dedent(it.rest)) : [];
      return {
        '@type': 'inputPageBlockListItem',
        blocks: [{ '@type': 'inputPageBlockParagraph', text: rich(first) }, ...inner],
        has_checkbox: hasBox,
        is_checked: checked,
        value: num ? Number(num[0]) : 0,
        type: num ? '1' : '',
      };
    }),
  };
}

function quoteBlock(lines) {
  const body = lines.map((l) => slice(l, /^\s*>\s?/.exec(l.text)[0].length));
  let credit = null;
  const last = body[body.length - 1];
  const c = last && /^\s*(?:—|--)\s*/.exec(last.text);
  if (c && body.length > 1 && last.text.slice(c[0].length).trim()) {
    credit = rich(trimmed(slice(last, c[0].length)));
    body.pop();
  }
  return { '@type': 'inputPageBlockBlockQuote', blocks: parseBlocks(body), credit };
}

/** Lines -> InputPageBlock blocks. */
function parseBlocks(lines) {
  const out = [];
  let para = [];
  const flushPara = () => {
    if (!para.length) return;
    out.push({ '@type': 'inputPageBlockParagraph', text: richLines(para) });
    para = [];
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const t = line.text.trim();

    // Code and a quote formatted in the field on whole lines.
    if (line.block.pre) {
      flushPara();
      const id = line.block.pre.id;
      const body = [];
      while (i < lines.length && lines[i].block.pre?.id === id) body.push(lines[i++].text);
      i -= 1;
      out.push({ '@type': 'inputPageBlockPreformatted', text: plain(body.join('\n')), language: line.block.pre.language || '' });
      continue;
    }
    if (line.block.quote) {
      flushPara();
      const id = line.block.quote.id;
      const body = [];
      while (i < lines.length && lines[i].block.quote?.id === id) {
        body.push({ ...lines[i], block: { ...lines[i].block, quote: undefined } });
        i += 1;
      }
      i -= 1;
      out.push({ '@type': 'inputPageBlockBlockQuote', blocks: parseBlocks(body), credit: null });
      continue;
    }

    if (!t) {
      flushPara();
      continue;
    }

    const fence = /^```\s*([\w+#.-]*)\s*$/.exec(t);
    if (fence) {
      flushPara();
      const body = [];
      i += 1;
      while (i < lines.length && lines[i].text.trim() !== '```') body.push(lines[i++].text);
      out.push({ '@type': 'inputPageBlockPreformatted', text: plain(body.join('\n')), language: fence[1] });
      continue;
    }

    if (t === '$$' || (t.startsWith('$$') && !t.slice(2).includes('$$'))) {
      flushPara();
      const body = [t.slice(2)];
      i += 1;
      while (i < lines.length && !lines[i].text.trim().endsWith('$$')) body.push(lines[i++].text);
      if (i < lines.length) body.push(lines[i].text.trim().slice(0, -2));
      out.push({ '@type': 'inputPageBlockMathematicalExpression', expression: body.join('\n').trim() });
      continue;
    }
    if (/^\$\$.+\$\$$/.test(t) && t.indexOf('$$', 2) === t.length - 2) {
      flushPara();
      out.push({ '@type': 'inputPageBlockMathematicalExpression', expression: t.slice(2, -2).trim() });
      continue;
    }

    const details = /^\+\+\+(!?)\s*/.exec(t);
    if (details) {
      flushPara();
      const head = slice(trimmed(line), details[0].length);
      const body = [];
      let depth = 1;
      i += 1;
      for (; i < lines.length; i += 1) {
        const lt = lines[i].text.trim();
        if (lt === '+++') {
          depth -= 1;
          if (!depth) break;
        } else if (/^\+\+\+!?\s*\S/.test(lt)) {
          depth += 1;
        }
        body.push(lines[i]);
      }
      out.push({
        '@type': 'inputPageBlockDetails',
        header: head.text.trim() ? rich(trimmed(head)) : plain('Details'),
        blocks: parseBlocks(body),
        is_open: details[1] === '!',
      });
      continue;
    }

    const heading = /^(#{1,6})\s+/.exec(t);
    if (heading) {
      flushPara();
      out.push({
        '@type': 'inputPageBlockSectionHeading',
        text: rich(trimmed(slice(trimmed(line), heading[0].length))),
        size: heading[1].length,
      });
      continue;
    }

    if (/^(-{3,}|\*{3,}|_{3,})$/.test(t)) {
      flushPara();
      out.push({ '@type': 'inputPageBlockDivider' });
      continue;
    }

    // Media; consecutive lines — a collage (only photos and videos — TDLib
    // shows nothing else in a collage), the rest — as blocks one by one.
    if (MEDIA_RE.test(t)) {
      flushPara();
      const group = [];
      while (i < lines.length && MEDIA_RE.test(lines[i].text.trim())) group.push(mediaLine(lines[i++]));
      i -= 1;
      const visual = (b) => b['@type'] === 'inputPageBlockPhoto' || b['@type'] === 'inputPageBlockVideo';
      if (group.length > 1 && group.every(visual)) {
        out.push({ '@type': 'inputPageBlockCollage', blocks: group, caption: null });
      } else {
        out.push(...group);
      }
      continue;
    }

    const buttons = buttonRow(t);
    if (buttons) {
      flushPara();
      out.push({ '@type': 'inputPageBlockButtonRow', buttons, align: null });
      continue;
    }

    if (t.startsWith('>')) {
      flushPara();
      const body = [];
      while (i < lines.length && lines[i].text.trim().startsWith('>') && !lines[i].block.quote) body.push(lines[i++]);
      i -= 1;
      out.push(quoteBlock(body));
      continue;
    }

    // "||spoiler||" at the start of a line is not a table.
    if (t.startsWith('|') && !t.startsWith('||')) {
      flushPara();
      const body = [];
      while (i < lines.length && lines[i].text.trim().startsWith('|')
          && !lines[i].text.trim().startsWith('||')) body.push(lines[i++]);
      i -= 1;
      out.push(tableBlock(body));
      continue;
    }

    if (LIST_RE.test(line.text)) {
      flushPara();
      const body = [line];
      const base = indentOf(line);
      i += 1;
      // Items and everything deeper than the base indent; an empty line
      // inside does not break the list if it continues after it.
      for (; i < lines.length; i += 1) {
        const l = lines[i];
        if (!l.text.trim()) {
          const next = lines[i + 1];
          if (next !== undefined && (indentOf(next) > base
              || (LIST_RE.test(next.text) && indentOf(next) >= base))) {
            body.push(l);
            continue;
          }
          break;
        }
        if (indentOf(l) > base
            || (LIST_RE.test(l.text) && indentOf(l) === base && sameKind(l.text, line.text))) {
          body.push(l);
          continue;
        }
        break;
      }
      i -= 1;
      out.push(listBlock(body));
      continue;
    }

    para.push(line);
  }
  flushPara();
  return out;
}

/**
 * The field's model ({ text, entities }, ui/editor.js) -> blocks; an empty
 * array — nothing to send. info(id) — info about an uploaded file
 * ({duration, w, h, thumb, tw, th}) or null. Throws if a file is still
 * uploading.
 */
export function composeRich(doc, info = () => null) {
  mediaInfo = info;
  try {
    return parseBlocks(toLines(doc));
  } finally {
    mediaInfo = () => null;
  }
}
