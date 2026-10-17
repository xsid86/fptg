import { el, clear } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { call } from '../core/net.js';
import { customEmojiNode } from '../util/emoji.js';
import { safeHref } from '../util/entities.js';
import { fileSize, duration } from '../util/format.js';
import { downloadUrl } from '../util/download.js';
import { inlineButtonNode } from './bots.js';

// Богатое сообщение (messageRichMessage, Bot API 10.1–10.3): статья из
// блоков, как Instant View, — заголовки, абзацы, списки, цитаты,
// таблицы, фото, видео, коллажи, раскрывающиеся блоки и строки кнопок.
//
// Структура — как у TDLib (pageBlock*, richText*, td_api.tl); сервер
// (webapi.RichFix) подменил в ней только файлы (id, size, url — '' пока
// не скачан: тогда file.ensure) и кнопки (JSON кнопок клавиатуры —
// нажатие через ui/bots.js, тот же обработчик, что под сообщением).
//
// richMessage.is_full false — пришло не всё: «Show the full message» ->
// rich.full (getFullRichMessage).

// ------------------------------------------------------------ файлы
/** Адрес файла: есть — сразу, нет — скачать (file.ensure). */
async function fileUrl(file) {
  if (!file) return '';
  if (file.url) return file.url;
  try {
    const r = await call('file.ensure', { fileId: file.id });
    file.url = r?.url || '';
  } catch {
    file.url = '';
  }
  return file.url;
}

const miniSrc = (mini) => (mini?.data ? `data:image/jpeg;base64,${mini.data}` : '');

/** Размер фото под показ: самый крупный не шире 1280, иначе самый крупный. */
function pickSize(photo) {
  const sizes = (photo?.sizes ?? []).filter((s) => s.photo);
  if (!sizes.length) return null;
  const fit = sizes.filter((s) => s.width <= 1280);
  const pool = fit.length ? fit : sizes;
  return pool.reduce((a, b) => (b.width * b.height > a.width * a.height ? b : a));
}

// ------------------------------------------------------------ текст
const STYLE_TAG = {
  richTextBold: 'b',
  richTextItalic: 'i',
  richTextUnderline: 'u',
  richTextStrikethrough: 's',
  richTextSubscript: 'sub',
  richTextSuperscript: 'sup',
  richTextMarked: 'mark',
  richTextFixed: 'code',
};

function link(href, children, cls = '') {
  return el('a', { class: cls, href: safeHref(href), target: '_blank', rel: 'noopener noreferrer' }, ...children);
}

/** RichText -> узлы (массив). */
function richText(t, msg) {
  if (!t) return [];
  const inner = () => richText(t.text, msg);
  switch (t['@type']) {
    case 'richTextPlain':
      return [document.createTextNode(t.text ?? '')];
    case 'richTexts':
      return (t.texts ?? []).flatMap((x) => richText(x, msg));
    case 'richTextSpoiler':
      return [el('span', { class: 'rich__spoiler', onclick: (e) => e.currentTarget.classList.add('is-open') }, ...inner())];
    case 'richTextUrl':
    case 'richTextReferenceLink':
    case 'richTextAnchorLink':
      return [link(t.url, inner())];
    case 'richTextEmailAddress':
      return [link(`mailto:${t.email_address}`, inner())];
    case 'richTextPhoneNumber':
      return [el('a', { href: `tel:${t.phone_number}` }, ...inner())];
    case 'richTextMention':
      return [link(`https://t.me/${t.username}`, inner(), 'mention')];
    case 'richTextMentionName':
      return [el('a', {
        class: 'mention', href: '#',
        onclick: (e) => { e.preventDefault(); emit('ui:open-contact', { userId: String(t.user_id) }); },
      }, ...inner())];
    case 'richTextCustomEmoji':
      return [customEmojiNode(String(t.custom_emoji_id), 'emoji--text') ?? document.createTextNode(t.alternative_text ?? '')];
    case 'richTextMathematicalExpression':
      return [el('code', { class: 'rich__math' }, t.expression ?? '')];
    case 'richTextButton':
      return t.button ? [inlineButtonNode(msg, t.button, 'rich__inline-btn')] : [];
    case 'richTextAnchor':
    case 'richTextIcon':
      return [];
    case 'richTextReference':
    case 'richTextDiff':
    case 'richTextDateTime':
    case 'richTextHashtag':
    case 'richTextCashtag':
    case 'richTextBankCardNumber':
    case 'richTextTonAddress':
    case 'richTextBotCommand':
      return inner();
    default: {
      const tag = STYLE_TAG[t['@type']];
      return tag ? [el(tag, {}, ...inner())] : inner();
    }
  }
}

const textNode = (tag, cls, t, msg) => el(tag, { class: cls }, ...richText(t, msg));

function caption(c, msg) {
  if (!c) return null;
  const text = richText(c.text, msg);
  const credit = richText(c.credit, msg);
  if (!text.length && !credit.length) return null;
  return el('figcaption', { class: 'rich__caption' },
    ...text, credit.length ? el('cite', { class: 'rich__credit' }, ...credit) : null);
}

const ALIGN = {
  pageBlockHorizontalAlignmentLeft: 'is-left',
  pageBlockHorizontalAlignmentCenter: 'is-center',
  pageBlockHorizontalAlignmentRight: 'is-right',
};

// ------------------------------------------------------------ медиа
function photoNode(photo, msg) {
  const size = pickSize(photo);
  const img = el('img', { class: 'rich__photo', alt: '', loading: 'lazy', src: miniSrc(photo?.minithumbnail) || null });
  if (size?.photo) {
    fileUrl(size.photo).then((url) => { if (url) img.src = url; });
  }
  return img;
}

/** Видео и анимация: кадр-заглушка, по щелчку — файл и проигрывание. */
function videoNode(video, autoplay, msg) {
  const v = el('video', {
    class: 'rich__video', controls: !autoplay, muted: autoplay, loop: autoplay,
    playsInline: true, preload: 'none',
    poster: miniSrc(video?.minithumbnail) || null,
  });
  const start = async () => {
    if (v.src) return;
    const url = await fileUrl(video?.video ?? video?.animation);
    if (!url) return;
    v.src = url;
    v.play().catch(() => {});
  };
  if (autoplay) start();
  else v.addEventListener('play', start, { once: true });
  return v;
}

/** Файл, аудио, голосовое — строкой с именем; по щелчку — скачать и открыть. */
function fileRow(file, name, sub, msg) {
  return el('button', {
    class: 'rich__file', type: 'button',
    onclick: async () => {
      const url = await fileUrl(file);
      if (url) window.location.href = downloadUrl(url, name, true);
    },
  }, el('span', { class: 'rich__file-name' }, name || 'File'),
  sub ? el('span', { class: 'rich__file-sub' }, sub) : null);
}

// ------------------------------------------------------------ блоки
function blocks(list, msg) {
  return (list ?? []).map((b) => block(b, msg)).filter(Boolean);
}

function block(b, msg) {
  switch (b?.['@type']) {
    case 'pageBlockTitle': return textNode('h1', 'rich__title', b.title, msg);
    case 'pageBlockSubtitle': return textNode('p', 'rich__subtitle', b.subtitle, msg);
    case 'pageBlockHeader': return textNode('h2', 'rich__header', b.header, msg);
    case 'pageBlockSubheader': return textNode('h3', 'rich__subheader', b.subheader, msg);
    case 'pageBlockSectionHeading':
      return textNode(`h${Math.min(6, Math.max(1, b.size || 2))}`, 'rich__heading', b.text, msg);
    case 'pageBlockKicker': return textNode('p', 'rich__kicker', b.kicker, msg);
    case 'pageBlockParagraph': return textNode('p', 'rich__p', b.text, msg);
    case 'pageBlockPreformatted': return textNode('pre', 'rich__pre', b.text, msg);
    case 'pageBlockFooter': return textNode('p', 'rich__footer', b.footer, msg);
    case 'pageBlockThinking': return textNode('p', 'rich__thinking', b.text, msg);
    case 'pageBlockDivider': return el('hr', { class: 'rich__hr' });
    case 'pageBlockMathematicalExpression': return el('pre', { class: 'rich__pre rich__math' }, b.expression ?? '');
    case 'pageBlockAnchor': return null;
    case 'pageBlockAuthorDate': {
      const date = b.publish_date ? new Date(b.publish_date * 1000).toLocaleDateString() : '';
      return el('p', { class: 'rich__byline' }, ...richText(b.author, msg), date ? ` · ${date}` : '');
    }
    case 'pageBlockList':
      return el('ul', { class: 'rich__list' }, ...(b.items ?? []).map((it) =>
        el('li', { class: 'rich__li' },
          it.has_checkbox ? el('input', { type: 'checkbox', checked: !!it.is_checked, disabled: true }) : null,
          // Маркер присылает TDLib (label: «•», «1.»); у пункта с
          // галочкой маркер — сама галочка.
          it.label && !it.has_checkbox ? el('span', { class: 'rich__li-label' }, it.label) : null,
          el('div', { class: 'rich__li-body' }, ...blocks(it.blocks, msg)))));
    case 'pageBlockBlockQuote':
      return el('blockquote', { class: 'rich__quote' }, ...blocks(b.blocks, msg),
        b.credit ? el('cite', { class: 'rich__credit' }, ...richText(b.credit, msg)) : null);
    case 'pageBlockPullQuote':
      return el('blockquote', { class: 'rich__quote rich__quote--pull' }, ...richText(b.text, msg),
        b.credit ? el('cite', { class: 'rich__credit' }, ...richText(b.credit, msg)) : null);
    case 'pageBlockExpandableBlockQuote': {
      const q = el('blockquote', { class: 'rich__quote is-collapsed' }, ...richText(b.text, msg),
        b.credit ? el('cite', { class: 'rich__credit' }, ...richText(b.credit, msg)) : null);
      q.addEventListener('click', () => q.classList.toggle('is-collapsed'));
      return q;
    }
    case 'pageBlockPhoto': {
      const img = photoNode(b.photo, msg);
      return el('figure', { class: 'rich__figure' },
        b.url ? link(b.url, [img]) : img, caption(b.caption, msg));
    }
    case 'pageBlockVideo':
      return el('figure', { class: 'rich__figure' }, videoNode(b.video, b.need_autoplay, msg), caption(b.caption, msg));
    case 'pageBlockAnimation':
      return el('figure', { class: 'rich__figure' }, videoNode(b.animation, true, msg), caption(b.caption, msg));
    case 'pageBlockAudio':
      return el('figure', { class: 'rich__figure' },
        fileRow(b.audio?.audio, b.audio?.title || b.audio?.file_name || 'Audio',
          b.audio?.duration ? duration(b.audio.duration) : '', msg), caption(b.caption, msg));
    case 'pageBlockVoiceNote':
      return el('figure', { class: 'rich__figure' },
        fileRow(b.voice_note?.voice, 'Voice message',
          b.voice_note?.duration ? duration(b.voice_note.duration) : '', msg), caption(b.caption, msg));
    case 'pageBlockDocument':
      return el('figure', { class: 'rich__figure' },
        fileRow(b.document?.document, b.document?.file_name,
          b.document?.document?.size ? fileSize(b.document.document.size) : '', msg), caption(b.caption, msg));
    case 'pageBlockCover':
      return block(b.cover, msg);
    case 'pageBlockCollage':
    case 'pageBlockSlideshow':
      return el('figure', { class: 'rich__figure' },
        el('div', { class: 'rich__collage' }, ...blocks(b.blocks, msg)), caption(b.caption, msg));
    case 'pageBlockEmbedded':
      // Чужой HTML внутрь окна не вставляется — только ссылка.
      return b.url ? el('p', { class: 'rich__p' }, link(b.url, [b.url])) : null;
    case 'pageBlockEmbeddedPost':
      return el('blockquote', { class: 'rich__quote' },
        el('p', { class: 'rich__byline' }, b.url ? link(b.url, [b.author || b.url]) : (b.author || '')),
        ...blocks(b.blocks, msg), caption(b.caption, msg));
    case 'pageBlockChatLink':
      return el('p', { class: 'rich__p' }, link(`https://t.me/${b.username}`, [b.title || `@${b.username}`], 'mention'));
    case 'pageBlockRelatedArticles':
      return el('div', { class: 'rich__related' },
        b.header ? textNode('h3', 'rich__subheader', b.header, msg) : null,
        ...(b.articles ?? []).map((a) => el('p', { class: 'rich__p' },
          link(a.url, [a.title || a.url]), a.description ? el('span', { class: 'rich__file-sub' }, ` — ${a.description}`) : null)));
    case 'pageBlockMap': {
      const loc = b.location ?? {};
      return el('p', { class: 'rich__p' },
        link(`https://www.openstreetmap.org/?mlat=${loc.latitude}&mlon=${loc.longitude}#map=${b.zoom || 15}/${loc.latitude}/${loc.longitude}`, ['Open the map']));
    }
    case 'pageBlockTable':
      return el('figure', { class: 'rich__figure' },
        el('div', { class: 'rich__table-wrap' },
          el('table', { class: `rich__table${b.is_bordered ? ' is-bordered' : ''}${b.is_striped ? ' is-striped' : ''}${b.is_compact ? ' is-compact' : ''}` },
            ...(b.cells ?? []).map((row) => el('tr', {},
              ...row.map((c) => el(c.is_header ? 'th' : 'td', {
                class: ALIGN[c.align?.['@type']] ?? '',
                colSpan: c.colspan > 1 ? c.colspan : null,
                rowSpan: c.rowspan > 1 ? c.rowspan : null,
              }, ...richText(c.text, msg))))))),
        b.caption ? el('figcaption', { class: 'rich__caption' }, ...richText(b.caption, msg)) : null);
    case 'pageBlockDetails':
      return el('details', { class: 'rich__details', open: !!b.is_open },
        el('summary', { class: 'rich__summary' }, ...richText(b.header, msg)),
        ...blocks(b.blocks, msg));
    case 'pageBlockButtonRow':
      return el('div', { class: `rich__buttons ${ALIGN[b.align?.['@type']] ?? ''}` },
        ...(b.buttons ?? []).map((btn) => inlineButtonNode(msg, btn, 'message__kb-btn')));
    default:
      return null;
  }
}

/** Тело богатого сообщения — зовёт message.js. */
export function renderRichMessage(msg) {
  const box = el('div', { class: `rich${msg.rich?.is_rtl ? ' is-rtl' : ''}` });
  const fill = (rich) => {
    clear(box).append(...blocks(rich?.blocks, msg));
    if (rich && rich.is_full === false) {
      box.append(el('button', {
        class: 'rich__more', type: 'button',
        onclick: async (e) => {
          e.currentTarget.disabled = true;
          try {
            const r = await call('rich.full', { id: String(msg.id) });
            if (r?.rich) fill(r.rich);
          } catch (err) {
            emit('ui:error', err.message);
          }
        },
      }, 'Show the full message'));
    }
  };
  fill(msg.rich);
  return box;
}
