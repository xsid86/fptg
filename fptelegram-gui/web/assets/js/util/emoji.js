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

/**
 * Merges the dictionary that came with a response, and answers whether
 * any id gained a url it did not have before.
 *
 * The caller needs to know, because a custom emoji resolving is NOT a
 * change to any message: the file arrives on its own schedule, the
 * message payload is identical before and after, and a view that
 * caches a node per payload will happily keep the placeholder for
 * ever. Measured on a live account: the sticker behind a reaction was
 * downloaded and on disk, and the pill still drew its dot, because the
 * node holding that dot was never asked to redraw.
 */
export function setCustomEmoji(dict) {
    if (!dict) return false;
    let fresh = false;
    for (const [id, info] of Object.entries(dict)) {
        if (!info?.url) continue;
        const key = String(id);
        if (known.get(key)?.url === info.url) continue;
        known.set(key, info);
        fresh = true;
    }
    return fresh;
}

/**
 * The url this id resolves to, or '' while its file is not here yet.
 * For caches keyed on a payload: the url is the part of what a node
 * draws that the payload itself does not carry.
 */
export function customEmojiUrl(id) {
    return known.get(String(id))?.url || '';
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
        // A still first frame, for the same reason the Lottie branch
        // below stops at one: a badge the size of a letter is not worth
        // waking the compositor sixty times a second for.
        //
        // AND IT HAS TO BE SEEKED THERE. `preload` fetches the data and
        // the decoder will happily hand that frame to a canvas - but a
        // video that has never played and never seeked has presented
        // nothing, so the element itself draws nothing and the badge is
        // simply absent. A seek is what makes a frame appear; the value
        // is a hair off zero because seeking to where you already are
        // is not a seek.
        const player = el('video', {
            class: cls,
            src: info.url,
            autoplay: false, loop: false, muted: true, playsInline: true,
            preload: 'auto',
            onloadeddata: () => { try { player.currentTime = 0.01; } catch { /* no data */ } },
        });
        return player;
    }
    if (info.format === 'tgs') {
        const frame = el('span', { class: `${cls} emoji--lottie` });
        // A custom emoji is drawn at the size of a letter. It is never
        // the thing being looked at, and it must not cost like one.
        playSticker(frame, info.url, { badge: true });
        return frame;
    }
    return el('img', { class: cls, src: info.url, alt: '' });
}
