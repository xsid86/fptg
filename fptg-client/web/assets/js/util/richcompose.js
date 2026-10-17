// Богатое сообщение из поля ввода -> блоки InputPageBlock для
// message.sendRich (td_api.tl: inputRichMessage, richMessageSourceBlocks).
//
// Markdown/HTML-источники TDLib — только для ботов, поэтому блоки
// собирает страница. Вход — модель поля (ui/editor.js): текст и
// сущности. Строчное оформление (жирный, ссылка, кастомный эмодзи…) —
// сущности; блоки — начало строки, привычный Markdown:
//
//   # Заголовок … ###### (размер 1–6)
//   - пункт / * пункт / 1. пункт / - [ ] задача / - [x] сделано
//     (вложенность — отступом в два пробела и больше)
//   > цитата (строки подряд; последняя «> — Автор» — подпись)
//   ```язык … ```          код (или строки, целиком оформленные кодом)
//   $$ … $$                формула (LaTeX)
//   ---                    разделитель
//   | a | b |              таблица; строка |---|:-:|--:| — шапка и выравнивание
//   +++ Заголовок … +++    раскрывающийся блок (+++! — открытый)
//   ![подпись](photo:id)   фото, видео (video:), GIF (gif:), аудио (audio:),
//                          файл (file:) — id загрузки POST /upload; строку
//                          вставляет поле ввода, когда файл прикреплён в
//                          режиме Rich. Несколько строк подряд — коллаж.
//   [[Текст|https://…]]    кнопка-ссылка; [[Текст|copy:текст]] — копирует
//                          текст; третьим полем стиль: primary, danger,
//                          success, link. Строка из одних кнопок — ряд кнопок,
//                          внутри абзаца — кнопка в тексте.
//
// В тексте ещё $$формула$$. Цитата и код, оформленные кнопками на целые
// строки, — тоже блоки.
//
// Обычный пользователь может только кнопки-ссылки, «пользователь» и
// «скопировать текст» (td_api.tl, inlineButton).

const plain = (text) => ({ '@type': 'richTextPlain', text });

// Сведения о загруженном файле (длительность, размеры, миниатюра видео)
// — на время одного composeRich, см. его параметр.
let mediaInfo = () => null;

const MEDIA_RE = /^!\[([^\]]*)\]\((photo|video|gif|audio|file|uploading):([^)\s]+)\)$/;
const upload = (id) => ({ '@type': 'inputFileUpload', id });

// ------------------------------------------------------------ строки
// Строка — { text, ents, block }: сущности со смещениями от начала
// строки; block — { pre, quote }: id сущностей-блоков, покрывающих
// строку целиком.

/** Модель поля -> строки. */
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

/** Кусок строки [from, to). */
function slice(line, from, to = line.text.length) {
  const ents = [];
  for (const e of line.ents) {
    const a = Math.max(e.offset, from);
    const b = Math.min(e.offset + e.length, to);
    if (b > a) ents.push({ ...e, offset: a - from, length: b - a });
  }
  return { text: line.text.slice(from, to), ents, block: line.block };
}

/** Без пробелов по краям. */
function trimmed(line) {
  const lead = /^\s*/.exec(line.text)[0].length;
  const tail = /\s*$/.exec(line.text)[0].length;
  return slice(line, lead, Math.max(lead, line.text.length - tail));
}

const indentOf = (line) => /^\s*/.exec(line.text)[0].length;

// ------------------------------------------------------------ строчное

/** Узлы RichText -> один RichText (соседние простые склеены). */
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

/** «Текст|цель|стиль» -> inlineButton, или null — не кнопка. */
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

/** Простой кусок текста: кнопки [[…]] и формулы $$…$$ внутри. */
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

// Вложение оформления: внутренние — первыми.
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

/** Строка -> RichText по её сущностям. */
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
      // Кастомный эмодзи заменяет свой текст (запасной обычный эмодзи).
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

/** Несколько строк -> один RichText через перевод строки. */
function richLines(lines) {
  const parts = [];
  lines.forEach((l, i) => {
    if (i) parts.push(plain('\n'));
    parts.push(rich(l));
  });
  return joinTexts(parts);
}

// ------------------------------------------------------------ медиа

/** Строка медиа -> блок InputPageBlock. */
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

/** Строка медиа -> блок, или null — не медиа. */
function mediaLine(line) {
  const t = trimmed(line);
  const m = MEDIA_RE.exec(t.text);
  if (!m) return null;
  return mediaBlock(m[2], m[3], slice(t, 2, 2 + m[1].length));
}

// ------------------------------------------------------------ блоки

const LIST_RE = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const ALIGN = {
  left: { '@type': 'pageBlockHorizontalAlignmentLeft' },
  center: { '@type': 'pageBlockHorizontalAlignmentCenter' },
  right: { '@type': 'pageBlockHorizontalAlignmentRight' },
};

// Нумерованный и маркированный списки подряд — два списка, не один.
const isNumbered = (text) => /^\d/.test(LIST_RE.exec(text)?.[2] ?? '');
const sameKind = (a, b) => isNumbered(a) === isNumbered(b);

/** Строка из одних кнопок [[…]] -> их список, иначе null. */
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

/** Ячейки строки таблицы: куски между «|», без краёв. */
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
  // Пункт — строка-маркер на базовом отступе, всё глубже — его
  // продолжение (абзац или вложенный список).
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

/** Строки -> блоки InputPageBlock. */
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

    // Код и цитата, оформленные в поле на целые строки.
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

    // Медиа; строки подряд — коллаж (только фото и видео — в коллаже
    // TDLib другого не показывает), остальное — блоками по одному.
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

    // «||спойлер||» в начале строки — не таблица.
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
      // Пункты и всё, что глубже базового отступа; пустая строка
      // внутри не рвёт список, если за ней он продолжается.
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
 * Модель поля ({ text, entities }, ui/editor.js) -> блоки; пустой
 * массив — отправлять нечего. info(id) — сведения о загруженном файле
 * ({duration, w, h, thumb, tw, th}) или null. Бросает, если файл ещё
 * грузится.
 */
export function composeRich(doc, info = () => null) {
  mediaInfo = info;
  try {
    return parseBlocks(toLines(doc));
  } finally {
    mediaInfo = () => null;
  }
}
