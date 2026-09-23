import { el } from '../core/dom.js';
import { playSticker } from '../ui/sticker.js';

// Custom (Telegram Premium) emoji: the ones that are really stickers
// sitting inside a line of text, and the status badge beside a premium
// account's name.
//
// WHAT COMES OVER THE WIRE is a dictionary per response - id to
// { format, url } - and ids AS TEXT, because a custom_emoji_id is a
// full 64-bit number and JSON numbers stop being exact at 2^53 (the
// same trap album ids already taught this project). Everything here
// keys on that text.
//
// An id with no url yet is a normal state, not an error: the file is
// still being fetched. The node builders answer null for it, and the
// callers leave the fallback character in place - which is what the
// text already contains, since Telegram sends a real emoji under every
// custom one.
//
// THE CHAT LIST ANIMATES THESE. The native window deliberately does
// not (see the long note on AnyPendingWork in customemoji.pas): one
// TBGRABitmap per emoji is shared between the list and the open
// history, so a live frame there would leak into the list on any
// unrelated repaint, and the answer was to freeze a copy. None of that
// applies here - the page has a real element per occurrence, and each
// one plays or pauses on its own.

const known = new Map();

/** Merges the dictionary that came with a response. */
export function setCustomEmoji(dict) {
    if (!dict) return;
    for (const [id, info] of Object.entries(dict)) {
        if (info && info.url) known.set(String(id), info);
    }
}

/**
 * An element that draws one custom emoji, or null when its file is not
 * here yet - then the caller keeps whatever text it was going to show.
 *
 * The three formats are the sticker formats, because that is what
 * these are: a still webp, a looping webm, or a Lottie animation
 * played by ui/sticker.js.
 */
export function customEmojiNode(id, extraClass = '') {
    const info = known.get(String(id));
    if (!info) return null;

    const cls = `emoji${extraClass ? ` ${extraClass}` : ''}`;
    if (info.format === 'webm') {
        return el('video', {
            class: cls,
            src: info.url,
            autoplay: true, loop: true, muted: true, playsInline: true,
        });
    }
    if (info.format === 'tgs') {
        const frame = el('span', { class: `${cls} emoji--lottie` });
        playSticker(frame, info.url);
        return frame;
    }
    return el('img', { class: cls, src: info.url, alt: '' });
}
