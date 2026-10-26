import { el } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { getPref, setPref, SCALES } from '../util/prefs.js';
import { playSticker } from './sticker.js';
import { themeList, currentTheme, setTheme } from './theme.js';
import { openBox, note } from './tgbox.js';
import {
  load, kept, one, td, failed, saving, refresh, group, row, uid, navRow, switchRow, radioRows,
  selectControl, intro, isPremium,
} from './setkit.js';

// "Chat settings", "Battery and animation" and "Language" — as in Telegram
// Desktop. This window's look (scale, theme, Enter, stickers, animations) —
// util/prefs.js and ui/theme.js, local; the quick reaction, sticker sets,
// the archive, 18+ and the language — the account, TDLib.

const bool = (answer) => !failed(answer) && answer.value === true;
const option = (name, value) => one('setOption', {
  name, value: typeof value === 'boolean'
    ? { '@type': 'optionValueBoolean', value }
    : { '@type': 'optionValueString', value },
});

// --------------------------------------------------------- quick reaction

function openQuickReaction(current, emojis) {
  openBox().push({
    title: 'Quick reaction',
    render: (body, box) => [
      note('Double-click a message to react with this emoji.'),
      el('div', { class: 'tgbox__emoji-grid' }, ...emojis.map((e) => el('button', {
        class: `tgbox__emoji${e === current ? ' is-active' : ''}`, type: 'button', title: e,
        onclick: async () => {
          await one('setDefaultReactionType', { reaction_type: { '@type': 'reactionTypeEmoji', emoji: e } });
          box.close();
          refresh();
        },
      }, e))),
    ],
    buttons: [{ label: 'Close', run: (box) => box.close() }],
  });
}

// --------------------------------------------------------- sticker sets

// A set's cover: the set's thumbnail, otherwise the first sticker (covers).
// The file — file.ensure; tgs — as a still frame (like an icon), webm — the
// first frame after seeking, the rest — as a picture.
function setThumb(set) {
  const frame = el('span', { class: 'tgbox__set-thumb' }, icon('smile'));
  const t = set.thumbnail;
  const cover = set.covers?.[0];
  let fileId = 0;
  let format = 'webp';
  if (t?.file?.id) {
    fileId = t.file.id;
    format = { thumbnailFormatTgs: 'tgs', thumbnailFormatWebm: 'webm' }[t.format?.['@type']] ?? 'webp';
  } else if (cover?.sticker?.id) {
    fileId = cover.sticker.id;
    format = { stickerFormatTgs: 'tgs', stickerFormatWebm: 'webm' }[cover.format?.['@type']] ?? 'webp';
  }
  if (!fileId) return frame;
  load('file.ensure', { fileId }).then(({ url }) => {
    if (!url || !frame.isConnected) return;
    if (format === 'tgs') {
      const host = el('span', { class: 'tgbox__set-lottie' });
      frame.replaceChildren(host);
      playSticker(host, url, { badge: true });
    } else if (format === 'webm') {
      const v = el('video', {
        src: url, muted: true, playsInline: true, preload: 'auto',
        onloadeddata: () => { try { v.currentTime = 0.01; } catch { /* no data */ } },
      });
      frame.replaceChildren(v);
    } else {
      frame.replaceChildren(el('img', { src: url, alt: '' }));
    }
  }).catch(() => {});
  return frame;
}

function openStickerSets(type, title) {
  openBox().push({
    title,
    async render(body, box) {
      const answer = await one('getInstalledStickerSets', { sticker_type: { '@type': type } });
      const sets = answer.sets ?? [];
      const change = (set, installed, archived) => async () => {
        await one('changeStickerSet', { set_id: set.id, is_installed: installed, is_archived: archived });
        box.refresh();
      };
      return [
        note(type === 'stickerTypeRegular'
          ? 'Sticker sets you added. They show up in the sticker panel in this order.'
          : 'Emoji packs you added. Custom emoji need Telegram Premium to be sent.'),
        sets.length ? el('div', { class: 'tgbox__list' }, ...sets.map((set) => el('div', { class: 'tgbox__peer' },
          setThumb(set),
          el('span', { class: 'tgbox__toggle-text' },
            el('span', { class: 'tgbox__row-label', title: set.title }, set.title),
            el('span', { class: 'tgbox__row-sub' }, `${set.size} ${type === 'stickerTypeRegular' ? 'stickers' : 'emoji'}`)),
          el('span', { class: 'tgbox__actions' },
            el('button', { class: 'btn tgbox__act', type: 'button', onclick: change(set, false, true) }, 'Archive'),
            el('button', { class: 'btn tgbox__act is-danger', type: 'button', onclick: change(set, false, false) }, 'Remove')))))
          : note('Nothing here yet.'),
      ];
    },
    buttons: [{ label: 'Close', run: (box) => box.close() }],
  });
}

// ----------------------------------------------------------- section

/**
 * Scale and theme — first, as at the start of Desktop's "Chat settings";
 * accent — the accent choice node from settings.js (swatchGrid).
 */
export async function renderChatSettings(accent) {
  const a = await td([
    { key: 'archive', method: 'getArchiveChatListSettings', soft: true },
    { key: 'canArchive', method: 'getOption', params: { name: 'can_archive_and_mute_new_chats_from_unknown_users' }, soft: true },
    { key: 'canSensitive', method: 'getOption', params: { name: 'can_ignore_sensitive_content_restrictions' }, soft: true },
    { key: 'sensitive', method: 'getOption', params: { name: 'ignore_sensitive_content_restrictions' }, soft: true },
  ]);
  let k = {};
  try {
    k = await kept(['updateDefaultReactionType', 'updateActiveEmojiReactions']);
  } catch {
    k = {};
  }
  const reaction = k.updateDefaultReactionType?.reaction_type;
  const reactionEmoji = reaction?.['@type'] === 'reactionTypeEmoji' ? reaction.emoji : '';
  const emojis = k.updateActiveEmojiReactions?.emojis ?? [];

  const scale = uid();
  const theme = uid();
  const look = group(null,
    row(scale, 'Interface scale', 'Text and controls of this window.',
      selectControl(scale, SCALES.map((s) => ({ value: s, label: s === 100 ? '100% (default)' : `${s}%` })),
        getPref('scale'), (v) => { setPref('scale', v); refresh(); })),
    row(theme, 'Theme', null,
      selectControl(theme, themeList().map((t) => ({ value: t.id, label: t.label })), currentTheme(),
        (v) => setTheme(v))),
    row(null, 'Accent color', 'Buttons, links, selection and unread counters.', accent));

  const sending = group('Send messages with',
    ...radioRows([
      { value: false, label: 'Enter', hint: 'Shift+Enter or Ctrl+Enter for a new line.' },
      { value: true, label: 'Ctrl+Enter', hint: 'Enter for a new line.' },
    ], getPref('sendByCtrlEnter'), (v) => setPref('sendByCtrlEnter', v)));

  const reactions = group('Reactions',
    navRow({
      label: 'Quick reaction', value: reactionEmoji || 'Not set',
      hint: 'Double-click a message to react with it.',
      onClick: emojis.length ? () => openQuickReaction(reactionEmoji, emojis) : null,
    }));

  const stickers = group('Stickers and emoji',
    navRow({ label: 'Sticker sets', onClick: () => openStickerSets('stickerTypeRegular', 'Sticker sets') }),
    navRow({ label: 'Emoji packs', onClick: () => openStickerSets('stickerTypeCustomEmoji', 'Emoji packs') }),
    switchRow('Loop animated stickers', 'Off: a sticker plays once each time it comes into view.',
      getPref('loopStickers'), (v) => setPref('loopStickers', v)));

  const arch = failed(a.archive) ? null : a.archive;
  const archiveMute = (patch) => saving(() => one('setArchiveChatListSettings', {
    settings: { ...arch, ...patch, '@type': 'archiveChatListSettings' },
  }));
  const canMute = bool(a.canArchive) || isPremium();
  const archive = arch ? group('Archive',
    switchRow('Keep unmuted chats archived',
      'Archived chats with notifications on stay in the archive when new messages arrive.',
      arch.keep_unmuted_chats_archived, (v) => archiveMute({ keep_unmuted_chats_archived: v })),
    switchRow('Keep chats from folders archived',
      'Archived chats that are in folders stay in the archive when new messages arrive.',
      arch.keep_chats_from_folders_archived, (v) => archiveMute({ keep_chats_from_folders_archived: v })),
    switchRow('Archive and mute new chats from non-contacts',
      'New chats from people who are not in your contacts go to the archive with notifications off.',
      arch.archive_and_mute_new_chats_from_unknown_users,
      (v) => archiveMute({ archive_and_mute_new_chats_from_unknown_users: v }),
      { premium: !canMute })) : null;

  const sensitiveId = uid();
  const canSensitive = bool(a.canSensitive);
  const sensitive = group('Sensitive content',
    row(sensitiveId, 'Show 18+ content',
      canSensitive
        ? 'Show media marked as sensitive without blurring it.'
        : 'Telegram allows this only for accounts it trusts. It is changed in the official apps.',
      el('span', { class: 'switch' },
        el('input', {
          class: 'switch__input', type: 'checkbox', id: sensitiveId, checked: bool(a.sensitive),
          disabled: !canSensitive,
          onchange: (e) => saving(() => option('ignore_sensitive_content_restrictions', e.target.checked)),
        }),
        el('span', { class: 'switch__track' }))));

  return [look, sending, reactions, stickers, archive, sensitive].filter(Boolean);
}

/** "Battery and animation": what comes alive and plays by itself. */
export async function renderPower() {
  let animatedEmojiOff = false;
  try {
    animatedEmojiOff = bool(await one('getOption', { name: 'disable_animated_emoji' }));
  } catch {
    animatedEmojiOff = false;
  }
  return [
    intro('Animations and autoplay use the processor and drain the battery. '
      + 'Turn off what you can do without.'),
    group('Stickers and emoji',
      switchRow('Animated stickers', 'Off: stickers stay still until clicked.',
        getPref('animatedStickers'), (v) => setPref('animatedStickers', v)),
      switchRow('Animated emoji', 'A message of one emoji arrives as a big animated one.',
        !animatedEmojiOff, (v) => saving(() => option('disable_animated_emoji', !v)))),
    group('Autoplay',
      switchRow('Autoplay GIFs', 'Off: a GIF plays when clicked.',
        getPref('autoplayGifs'), (v) => setPref('autoplayGifs', v)),
      switchRow('Autoplay videos', 'Muted while on screen; a click plays it from the start with sound.',
        getPref('autoplayVideos'), (v) => setPref('autoplayVideos', v))),
    group('Interface',
      switchRow('Interface animations', 'Fades and slides of panels, menus and windows.',
        getPref('interfaceAnimations'), (v) => setPref('interfaceAnimations', v))),
  ];
}

/** "Language": the language of the texts Telegram itself sends. */
export async function renderLanguage() {
  const ask = () => td([
    { key: 'packs', method: 'getLocalizationTargetInfo', params: { only_local: false }, soft: true },
    { key: 'current', method: 'getOption', params: { name: 'language_pack_id' }, soft: true },
  ]);
  let a = await ask();
  // TDLib language packs are by "target" (the application); our server has
  // none until it is set. We take the Telegram Desktop set, as it does itself.
  if (failed(a.packs) && /localization_target/.test(a.packs?.message ?? '')) {
    await option('localization_target', 'tdesktop');
    a = await ask();
  }
  const head = intro('The app’s own interface is in English. The language here is the one Telegram '
    + 'uses for texts it sends to this account: service messages, notifications and the like.');
  if (failed(a.packs) || !(a.packs.language_packs ?? []).length) {
    return [head, intro(failed(a.packs) ? a.packs?.message ?? 'Languages are not available.' : 'No languages.')];
  }
  const current = failed(a.current) ? 'en' : (a.current.value || 'en');
  const packs = a.packs.language_packs.filter((p) => p.is_official || p.is_installed);
  return [head, group(null,
    ...radioRows(packs.map((p) => ({ value: p.id, label: p.native_name, hint: p.name })), current,
      (v) => saving(() => option('language_pack_id', v))))];
}

