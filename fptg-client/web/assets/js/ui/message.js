import {el, clear} from '../core/dom.js';
import {emit} from '../core/bus.js';
import {icon} from '../util/icons.js';
import {playSticker, restyleStickers} from './sticker.js';
import {customEmojiNode} from '../util/emoji.js';
import {renderRichText} from '../util/entities.js';
import {holdImage, holdVideo, setVideoMode} from '../util/offscreen.js';
import {clockTime, fileSize, duration, signedDuration} from '../util/format.js';
import {addRing, xferText, xferLeft} from '../util/xfer.js';
import {peopleOnHover} from './people.js';
import {renderInlineKeyboard} from './bots.js';
import {renderRichMessage} from './richmessage.js';
import {mapUrl, openMapPoint} from '../util/maps.js';
import {fillAvatar} from '../util/avatar.js';
import {copyText} from '../util/clipboard.js';
import {translationFor, watchTranslation} from './translate.js';
import {downloadUrl} from '../util/download.js';
import {getPref} from '../util/prefs.js';
import {on} from '../core/bus.js';
import {store, openThread} from '../core/store.js';

// The animation settings changed — GIFs and stickers already shown play by
// the new rules at once, without redrawing the history.
function restyleMedia() {
    const loop = getPref('loopStickers');
    const still = !getPref('animatedStickers');
    for (const v of document.querySelectorAll('video.media__video:not([controls])')) {
        setVideoMode(v, getPref('autoplayGifs') ? 'loop' : false);
    }
    for (const v of document.querySelectorAll('video.media__sticker')) {
        v.loop = loop && !still;
        setVideoMode(v, still ? false : (loop ? 'loop' : 'once'));
    }
    restyleStickers(document.body, {loop, still});
}
for (const key of ['autoplayGifs', 'loopStickers', 'animatedStickers']) on(`pref:${key}`, restyleMedia);

// One message block, following framehistory.pas rather than inventing a
// second visual language: a tinted header line (status mark, sender,
// time) over the body, the whole card carrying the sender's accent, and
// reactions as a strip along the bottom.
//
// Own messages sit on the right, others on the left (2026-10-12; the
// native window's single column before that) - blocks/_message.scss,
// not here: the card is the same either way.

const RECEIPT_ICON = {
    sent: 'check',
    read: 'check-double',
    pending: 'clock',
    failed: 'alert',
};

/**
 * The right-click menu belongs to the message, so the card carries it.
 *
 * It opens AT THE POINTER: against a tall message - a code block, an
 * album - a menu pinned to the card's edge can end up far enough away
 * that which message it belongs to stops being obvious. The card still
 * travels with it as what the menu is ABOUT, which is what decides when
 * it has to close.
 */
function withMenu(card, msg) {
    card.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        emit('ui:message-menu', {
            msg,
            anchor: card,
            at: {x: event.clientX, y: event.clientY},
        });
    });
    return card;
}

// The players of the same message's previous node, by file address. A
// message is rebuilt whole on any change of its payload (reactions, the
// comment counter, transfer progress — a live log: 28 reaction changes in
// one channel in 9 minutes), and the new <video> pulled the file anew — a
// native loading indicator flashed on a video not yet started, and a
// playing one stopped. Now the same element moves into the new node: a
// move within one task does not interrupt playback (the element does not
// manage to be outside the document by the "stable state").
let reusable = null;

/**
 * Like renderMessage, but videos with the same address are taken from
 * `oldNode` rather than created anew. The address is data-media: the player
 * loses src when it goes off screen (util/offscreen.js releases the decoder).
 */
export function renderMessageReusing(msg, oldNode) {
    // A node outside the document may have gone through the sweep already
    // (util/offscreen.js): its players have no src and no observers, they cannot be moved.
    if (!oldNode?.isConnected) return renderMessage(msg);
    reusable = new Map();
    for (const video of oldNode.querySelectorAll('video[data-media]')) {
        reusable.set(video.dataset.media, video);
    }
    try {
        return renderMessage(msg);
    } finally {
        reusable = null;
    }
}

/** The previous node's player for this address, or null — then build a new one. */
function takeVideo(url) {
    const video = reusable?.get(url) ?? null;
    if (video) reusable.delete(url);
    return video;
}

export function renderMessage(msg) {
    // A service message (group created, joined, pinned…) — a line in the
    // middle of the history, without a bubble or header.
    if (msg.service) {
        return withMenu(el('div', {
            class: 'message-service',
            dataset: {messageId: String(msg.id)},
        }, el('span', {class: 'message-service__text'}, msg.text || '')), msg);
    }
    const card = el('article', {
        class: [
            'message',
            `accent-${msg.senderColor}`,
            msg.outgoing ? 'message--outgoing' : '',
            // A round video — like a sticker: no backdrop, only the header.
            msg.kind === 'sticker' || msg.media?.round ? 'message--sticker' : '',
        ].filter(Boolean).join(' '),
        dataset: {messageId: String(msg.id)},
    });

    // A sticker has no bubble, so a strip under it is a bar of its own
    // across the history - worth it for reactions, absurd for a
    // comments button reading zero. On a sticker the button moves up
    // into the head, where there is room going spare, and only once
    // there is something to count.
    const bare = msg.kind === 'sticker' || !!msg.media?.round;
    card.append(renderHead(msg, bare && msg.comments > 0));
    if (msg.reply) card.append(renderReply(msg));
    if (msg.forward) card.append(renderForward(msg));

    const body = el('div', {class: 'message__body'});
    const media = renderMedia(msg);
    if (media) body.append(media);
    if (msg.kind === 'poll' && msg.poll) body.append(renderPoll(msg));
    if (msg.kind === 'location' && msg.location) body.append(renderLocation(msg));
    if (msg.kind === 'contact' && msg.contact) body.append(renderContact(msg));
    if (msg.kind === 'call' && msg.call) body.append(renderCall(msg));
    // A rich message — an article of blocks with buttons (ui/richmessage.js).
    if (msg.kind === 'rich' && msg.rich) body.append(renderRichMessage(msg));
    // The chat's translation is on and ready — it replaces the text (ui/translate.js).
    const tr = translationFor(msg);
    if (msg.text) body.append(renderRichText(tr ? tr.text : msg.text, tr ? tr.entities : (msg.entities ?? [])));
    if (tr) body.append(el('div', {class: 'message__translated'}, 'Translated'));
    if (msg.link) body.append(renderLinkPreview(msg));
    if (body.childNodes.length) card.append(body);

    const footer = renderFooter(msg, bare);
    if (footer) card.append(footer);
    watchTranslation(card, msg);
    // The bot's buttons under the message (ui/bots.js).
    if (msg.keyboard?.length) card.append(renderInlineKeyboard(msg));
    return withMenu(card, msg);
}

/**
 * An album: several messages Telegram sent together, drawn as one
 * bubble with a grid, the way the original client does.
 *
 * The per-kind renderers are reused unchanged, so every cell keeps the
 * click, the download and the progress bar it already had - that is
 * most of the reason to build it this way rather than to draw a
 * special-case grid of bare <img>.
 */
export function renderAlbum(msgs) {
    const lead = msgs[0];
    const card = el('article', {
        class: [
            'message',
            'message--album',
            `accent-${lead.senderColor}`,
            lead.outgoing ? 'message--outgoing' : '',
        ].filter(Boolean).join(' '),
        dataset: {messageId: String(lead.id), albumId: lead.albumId},
    });

    card.append(renderHead(lead));
    if (lead.reply) card.append(renderReply(lead));
    if (lead.forward) card.append(renderForward(lead));

    const grid = el('div', {class: 'album'});
    let at = 0;
    for (const count of albumRowCounts(msgs.length)) {
        const run = msgs.slice(at, at + count);
        at += count;
        // The cells' own grow factors, added up: that sum IS the row's
        // aspect ratio, so the row is exactly as tall as those widths
        // are honest. Rounded the same way on both sides, or the cells
        // would not fill the height they were given.
        const ars = run.map(cellAspect);
        const sum = ars.reduce((a, b) => a + b, 0);
        const row = el('div', {
            class: `album__row album__row--ar-${clamp(Math.round(sum / 10), 10, 60)}`,
        });
        run.forEach((m, k) => {
            row.append(el('div', {
                class: `album__cell album__cell--ar-${ars[k]}`,
            }, renderMedia(m, msgs)));
        });
        grid.append(row);
    }

    const body = el('div', {class: 'message__body'});
    body.append(grid);
    // Telegram allows exactly one caption per album, on whichever
    // message happened to carry it - so it is looked for rather than
    // taken from the first.
    const captioned = msgs.find((m) => m.text);
    const ctr = captioned ? translationFor(captioned) : null;
    if (captioned) body.append(renderRichText(ctr ? ctr.text : captioned.text, ctr ? ctr.entities : (captioned.entities ?? [])));
    if (ctr) body.append(el('div', {class: 'message__translated'}, 'Translated'));
    if (captioned) watchTranslation(card, captioned);
    card.append(body);

    // The strip belongs to whichever message in the run carries the
    // reactions or the comment count - Telegram hangs both on one
    // message of an album, not on every cell.
    const footed = msgs.find((m) => m.reactions?.length || m.comments > 0
        || (m.comments !== undefined && inChannelFeed()));
    if (footed) {
        const strip = renderFooter(footed);
        if (strip) card.append(strip);
    }
    // An album is one bubble but several messages; the menu acts on the
    // first, which is the one Telegram itself treats as the album's own
    // (its id is what carries the reactions and the album id).
    return withMenu(card, lead);
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/**
 * How many items each row of an album holds.
 *
 * Rows of three, with the two awkward remainders spent where they show
 * least: two left over become a short leading row (5 reads as 2+3, 8 as
 * 2+3+3), one left over turns the last four into 2+2 rather than
 * leaving a single cell stretched across the width. That is the
 * client's arrangement for the common counts; what it also weighs, and
 * this does not, is which pictures happen to be portrait.
 */
function albumRowCounts(n) {
    if (n <= 3) return [n];
    if (n === 4) return [2, 2];
    if (n === 5) return [2, 3];

    const rows = [];
    let left = n;
    if (left % 3 === 2) {
        rows.push(2);
        left -= 2;
    }
    while (left > 4) {
        rows.push(3);
        left -= 3;
    }
    if (left === 4) rows.push(2, 2);
    else if (left > 0) rows.push(left);
    return rows;
}

/**
 * A cell's aspect ratio in hundredths, on the ladder blocks/_album.scss
 * generates - the width of that cell within its row.
 *
 * Clamped, because the ladder ends somewhere and because one panorama
 * should not flatten a whole row: past the ends the picture is cropped
 * instead. Media that never reported a size reads as square, which is
 * the least wrong guess for a thumbnail that has not arrived.
 */
function cellAspect(msg) {
    const m = msg.media ?? {};
    const ar = m.w > 0 && m.h > 0 ? m.w / m.h : 1;
    return clamp(Math.round(ar * 20) * 5, 70, 170);
}

// ------------------------------------------------------------- head
function renderHead(msg, withComments = false) {
    const head = el('header', {class: 'message__head'});

    // Only the read receipt, and only on our own messages - an
    // incoming one has nothing to report. What used to stand in this
    // slot for everything else was an icon for the message's KIND, and
    // it said nothing the message itself was not already showing: a
    // photo above a little photo glyph.
    const receipt = RECEIPT_ICON[msg.receipt];
    if (receipt) {
        // Hover — who read it (ui/people.js). The wrapper is needed: the
        // icon itself has pointer-events: none.
        const hit = el('span', {class: 'message__receipt-hit'}, icon(receipt, 'message__receipt'));
        peopleOnHover(hit, {id: String(msg.id), what: 'viewers'}, 'Seen by');
        head.append(hit);
    }

    // The sender's avatar before the name.
    const avatar = el('span', {class: `avatar message__avatar accent-${msg.senderColor || 'a5'}`});
    fillAvatar(avatar, {
        id: msg.senderId,
        title: msg.senderName || (msg.outgoing ? 'You' : '?'),
        avatar: msg.senderAvatar || '',
        avatarThumb: msg.senderThumb || '',
    });
    head.append(avatar);
    head.append(el('span', {
        class: 'message__sender',
        textContent: msg.senderName || (msg.outgoing ? 'You' : 'Unknown'),
    }));
    head.append(el('span', {class: 'message__time', textContent: clockTime(msg.date)}));
    if (msg.editDate) {
        head.append(el('span', {class: 'message__state', textContent: 'edited'}));
    }
    // A bot's ephemeral content — visible only to this user.
    if (msg.ephemeral) {
        head.append(el('span', {class: 'message__state', textContent: 'only you can see this'}));
    }
    if (withComments) {
        head.append(el('span', {class: 'message__head-gap'}));
        head.append(renderComments(msg));
    }
    return head;
}

// ----------------------------------------------------- link preview
/**
 * The card Telegram builds for a link, drawn under the text.
 *
 * Nothing here is worked out by this client: the site, the title, the
 * description and a ready-to-download picture all arrive inside the
 * message (messageText.link_preview). So the only decisions left are
 * layout ones.
 *
 * `large` is the server's own opinion - show_large_media - on whether
 * this preview earns the wide picture above the text or the small
 * square beside it. Following it rather than measuring the image is
 * what keeps a news card looking like a news card and a favicon-sized
 * article image from being blown up to the width of the bubble.
 */
function renderLinkPreview(msg) {
    const p = msg.link;
    const wide = !!(p.large && p.url_photo);
    const card = el('a', {
        class: `link-preview${wide ? ' link-preview--wide' : ''}`,
        href: p.url,
        target: '_blank',
        rel: 'noopener noreferrer',
        title: p.url,
    });

    if (p.w > 0 || p.thumb) {
        const shot = el('span', {class: 'link-preview__shot'});
        const bg = el('div', {
            class: 'link-preview__img-bg',
            style: `background-image: url(${p.url_photo || p.thumb || ''})`
        });
        shot.append(bg);
        const shown = el('img', {
            class: p.url_photo ? 'link-preview__img' : 'link-preview__img is-placeholder',
            src: p.url_photo || p.thumb || '',
            alt: '',
            loading: 'lazy',
        });
        if (p.url_photo) holdImage(shown, p.url_photo, p.thumb);
        shot.append(shown);
        card.append(shot);
        if (!p.url_photo) ensure(msg, 'link');
    }

    const body = el('span', {class: 'link-preview__body'});
    if (p.site) body.append(el('span', {class: 'link-preview__site', textContent: p.site}));
    if (p.title) body.append(el('span', {class: 'link-preview__title', textContent: p.title}));
    if (p.text) body.append(el('span', {class: 'link-preview__text', textContent: p.text}));
    // A card with nothing but a picture still has to say where it goes.
    if (!body.childNodes.length) {
        body.append(el('span', {class: 'link-preview__site', textContent: p.display || p.url}));
    }
    card.append(body);
    return card;
}

// ------------------------------------------------------------ reply
function renderReply(msg) {
    const banner = el('button', {
        class: `message__reply accent-${msg.reply.color ?? msg.senderColor}`,
        type: 'button',
        // The quoted message may well be in another chat - a comment
        // quotes the channel's post. Where it is, is the server's to
        // say; what to do about it is main.js's.
        onclick: () => emit('ui:open-source', {
            chatId: msg.reply.chatId,
            messageId: msg.reply.id,
        }),
    }, icon('reply'));

    banner.append(el('span', {
        class: 'message__reply-name',
        textContent: msg.reply.name ?? '',
    }));
    banner.append(el('span', {
        class: 'message__reply-text',
        // No text yet means the quoted message is still being fetched -
        // the model starts that itself and the answer arrives through the
        // ordinary change signal, so this fills in on a later render.
        textContent: msg.reply.text ?? '…',
    }));
    return banner;
}

// ---------------------------------------------------------- forward
function renderForward(msg) {
    const canJump = Boolean(msg.forward.messageId);
    const card = el(canJump ? 'button' : 'div', {
        class: `message__forward accent-${msg.forward.color ?? msg.senderColor}`,
        type: canJump ? 'button' : null,
        onclick: canJump
            ? () => emit('ui:open-source', {
                chatId: msg.forward.chatId,
                messageId: msg.forward.messageId,
            })
            : null,
    });
    card.append(el('span', {class: 'message__forward-label', textContent: 'Forwarded from'}));
    card.append(el('span', {
        class: 'message__forward-name',
        textContent: msg.forward.name || 'Hidden sender',
    }));
    return card;
}

// ----------------------------------------------------------- media
/**
 * `group` is the album this message belongs to, when it does: a click
 * has to open the gallery on the right slide, and only the caller knows
 * what the run was.
 */
function renderMedia(msg, group) {
    const m = msg.media;
    if (!m) return null;

    switch (msg.kind) {
        case 'photo':
            return renderPhoto(msg, m, group);
        case 'video':
            if (m.round) return renderVideoNote(msg, m);
            return group ? renderVideoCell(msg, m, group) : renderVideo(msg, m);
        case 'animation':
            return renderAnimation(msg, m);
        case 'audio':
            return renderAudio(msg, m);
        case 'voice':
            return renderVoice(msg, m);
        case 'file':
            return renderFile(msg, m);
        case 'sticker':
            return renderSticker(msg, m);
        default:
            return null;
    }
}

// The square a preview is fitted into. Keep in sync with
// $media-max-width / $media-max-height in abstracts/_variables.scss -
// the box is sized here in JavaScript and capped there in CSS, and the
// two have to agree or the cap moves the box after it is placed.
const MEDIA_CAP = 420;

/**
 * The classes for one media box: the block, the rung of the ratio
 * ladder that gives the box the shape of what is inside it, and the
 * rung of the width ladder that says how big it is.
 *
 * Without the ratio the box is sized by the original's width and ends
 * up wider than the capped picture, which is what used to show as a
 * grey margin beside every landscape photo. See .media--sized in
 * blocks/_media.scss for why the cap alone cannot fix that.
 *
 * Without the WIDTH the box is sized by its content, and the content
 * of a picture that has not downloaded yet is the ~40px stamp riding
 * inside the message - so the box stood at its 200px floor until the
 * file arrived and then sprang to the full 420. Every such spring
 * moves everything below it, which is the history jumping under the
 * reader's eyes while a screenful of previews lands. TDLib reports the
 * size in the message itself, long before the bytes, so the final size
 * is known from the first paint and nothing has to move.
 */
function sizedBox(kind, m) {
    const base = `media media--${kind}`;
    // Nothing said how big this is: the box cannot promise a size it
    // does not know, so it keeps the old stand-in and the old jump.
    if (!(m.w > 0 && m.h > 0)) return `${base} media--guess`;
    const ar = clamp(Math.round((m.w / m.h) * 20) * 5, 40, 400);
    return `${base} media--sized media--ar-${ar} media--w-${shownWidth(m.w, ar)}`;
}

/**
 * How wide the box ends up: the original, fitted into the cap square,
 * snapped to the ladder's five-pixel step.
 *
 * Computed off the ratio RUNG rather than off w/h, so the height CSS
 * derives from it (width / rung) lands inside the cap too - taking the
 * true ratio here would let a portrait come out a few pixels too tall
 * and be clipped by max-height, which is a size change again.
 */
function shownWidth(w, ar) {
    const fit = Math.min(w, MEDIA_CAP, MEDIA_CAP * (ar / 100));
    return clamp(Math.round(fit / 5) * 5, 40, MEDIA_CAP);
}

function ensure(msg, what) {
    emit('ui:ensure-media', {id: msg.id, what});
}

/**
 * A click on the ring: a download stops, an outgoing message is deleted, as
 * in the native client (TTdMessages.CancelTransfer). While the transfer is
 * running, the ring has a cross — so it is clear a click cancels, not downloads.
 */
function cancelTransfer(msg) {
    emit('ui:cancel-transfer', {id: msg.id});
}

/**
 * "How much of how much" in the corner of the picture while the file is
 * transferred (down or up), or nothing. The ring itself is on the button in
 * the middle (overlay / xferOverlay); there used to be a linear bar here,
 * only for photos and videos and only for downloads.
 */
function progress(m) {
    if (!m.xfer) return null;
    return el('span', {class: 'media__xfer u-tabular', textContent: xferText(m.xfer)});
}

/**
 * A ring over a picture whose file is here already but is still going out —
 * an outgoing photo, video, GIF. A click cancels the sending; it does not go
 * further to the picture (the viewer).
 */
function xferOverlay(msg, m) {
    return addRing(el('button', {
        class: 'media__overlay',
        type: 'button',
        title: 'Cancel',
        onclick: (event) => {
            event.stopPropagation();
            cancelTransfer(msg);
        },
    }, icon('close')), m.xfer);
}

/**
 * The affordance over a picture that is not downloaded yet.
 *
 * One centred button with a download arrow, which is what the native
 * widgets draw (AUDIO_ICON_DOWNLOAD over the preview). It replaced a
 * full-size translucent panel with a 72px icon and a caption - that
 * was the web's own invention, and at four cards a screen it read as a
 * fog over the history rather than as a button.
 */
function overlay(name, onclick, m, msg) {
    // While the file downloads — a progress ring around the button and a
    // cross in it: a click cancels the download.
    if (m?.xfer) {
        return addRing(el('button', {
            class: 'media__overlay',
            type: 'button',
            title: 'Cancel',
            onclick: (event) => {
                event.stopPropagation();
                cancelTransfer(msg);
            },
        }, icon('close')), m.xfer);
    }
    return el('button', {
        class: 'media__overlay',
        type: 'button',
        title: 'Download',
        onclick,
    }, icon(name));
}

function renderPhoto(msg, m, group) {
    const boxWrapper = el('div', {class: 'media__wrapper'});
    const box = el('div', {class: sizedBox('photo', m)});
    const img = el('img', {
        class: m.url ? 'media__img' : 'media__img is-placeholder',
        src: m.url || m.thumb || '',
        alt: '',
        loading: 'lazy',
    });
    // Released again once it is far from the screen - see
    // util/offscreen.js. Only when the file is really here: one still
    // waiting for its download is already wearing the stamp.
    if (m.url) holdImage(img, m.url, m.thumb);
    box.append(img);
    if (m.url) {
        box.classList.add('is-clickable');
        box.addEventListener('click', () => emit('ui:view', {msg, group}));
        if (m.xfer) box.append(xferOverlay(msg, m));
    } else {
        box.classList.add('is-pending');
        box.append(overlay('download', () => ensure(msg, 'preview'), m, msg));
    }
    const p = progress(m);
    if (p) box.append(p);
    boxWrapper.append(box);
    return boxWrapper;
}

function renderVideo(msg, m) {
    const boxWrapper = el('div', {class: 'media__wrapper'});
    const box = el('div', {class: sizedBox('video', m)});
    if (m.url) {
        const reused = takeVideo(m.url);
        const player = reused ?? el('video', {
            class: 'media__video',
            src: m.url,
            poster: m.thumbUrl || '',
            controls: true,
            preload: 'metadata',
            dataset: {media: m.url},
        });
        if (!reused) holdVideo(player, m.url);
        box.append(player);
        if (m.xfer) box.append(xferOverlay(msg, m));
    } else {
        const still = el('img', {
            class: m.thumbUrl ? 'media__img' : 'media__img is-placeholder',
            src: m.thumbUrl || '',
            alt: '',
            loading: 'lazy',
        });
        if (m.thumbUrl) holdImage(still, m.thumbUrl, m.thumb);
        box.append(still);
        box.classList.add('is-pending');
        box.append(overlay('download', () => ensure(msg, 'full'), m, msg));
        if (m.duration) {
            box.append(el('span', {class: 'media__badge', textContent: duration(m.duration)}));
        }
    }
    const p = progress(m);
    if (p) box.append(p);
    boxWrapper.append(box);
    return boxWrapper;
}

/**
 * A video message ("round video"), as in Telegram Desktop: a circle without
 * a bubble, paused by default — a preview frame, a "play" button and the
 * duration. A click — play with sound, a progress ring around the circle
 * (gap 2px, width 3px, the accent colour); another click — pause; played to
 * the end — back to the start, the ring hides.
 */
// The ring: circle 240 — centred in a 250 box, radius 120 + gap 2 + half the width.
const ROUND_RING_BOX = 250;
const ROUND_RING_R = 123.5;
const SVG_NS = 'http://www.w3.org/2000/svg';

function roundRing() {
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('class', 'media-round__ring');
    svg.setAttribute('viewBox', `0 0 ${ROUND_RING_BOX} ${ROUND_RING_BOX}`);
    svg.setAttribute('aria-hidden', 'true');
    const arc = document.createElementNS(SVG_NS, 'circle');
    const c = ROUND_RING_BOX / 2;
    arc.setAttribute('cx', String(c));
    arc.setAttribute('cy', String(c));
    arc.setAttribute('r', String(ROUND_RING_R));
    // The circumference is 100: progress in percent right in dasharray.
    arc.setAttribute('pathLength', '100');
    arc.setAttribute('stroke-dasharray', '0 100');
    // The start — at the top, clockwise.
    arc.setAttribute('transform', `rotate(-90 ${c} ${c})`);
    svg.classList.add('is-empty');
    svg.append(arc);
    return {
        svg,
        set(part) {
            const p = Math.max(0, Math.min(100, part * 100));
            arc.setAttribute('stroke-dasharray', `${p.toFixed(2)} 100`);
            // Zero with rounded caps is a dot: an empty ring is hidden.
            svg.classList.toggle('is-empty', p < 0.5);
        },
    };
}

function renderVideoNote(msg, m) {
    const box = el('div', {class: 'media media--round'});
    const clip = el('div', {class: 'media-round__clip'});
    box.append(clip);
    const badge = m.duration
        ? el('span', {class: 'media-round__badge', textContent: duration(m.duration)}) : null;
    if (m.url) {
        const player = el('video', {
            class: 'media-round__video',
            src: m.url,
            poster: m.thumbUrl || '',
            playsInline: true,
            preload: 'metadata',
        });
        // Only releasing the file far from the screen — it does not play by itself.
        holdVideo(player, m.url);
        clip.append(player);
        const ring = roundRing();
        const play = el('span', {class: 'media-round__play'}, icon('play'));
        box.append(ring.svg, play, el('span', {class: 'media-round__wait', 'aria-hidden': 'true'}));
        box.classList.add('is-clickable');
        box.addEventListener('click', () => {
            if (player.paused) player.play().catch(() => {});
            else player.pause();
        });
        player.addEventListener('play', () => box.classList.add('is-playing', 'is-started'));
        player.addEventListener('pause', () => box.classList.remove('is-playing', 'is-waiting'));
        // Waiting for data (slow network) — a steady arc over the video.
        player.addEventListener('waiting', () => box.classList.add('is-waiting'));
        player.addEventListener('playing', () => box.classList.remove('is-waiting'));
        player.addEventListener('timeupdate', () => {
            const total = player.duration || m.duration || 0;
            if (total) ring.set(player.currentTime / total);
            if (badge) badge.textContent = duration(Math.max(0, Math.round(total - player.currentTime)));
        });
        player.addEventListener('ended', () => {
            box.classList.remove('is-playing', 'is-started', 'is-waiting');
            player.currentTime = 0;
            ring.set(0);
            if (badge) badge.textContent = duration(m.duration);
        });
        if (m.xfer) box.append(xferOverlay(msg, m));
    } else {
        const still = el('img', {
            class: m.thumbUrl ? 'media-round__video' : 'media-round__video is-placeholder',
            src: m.thumbUrl || '',
            alt: '',
            loading: 'lazy',
        });
        clip.append(still);
        box.classList.add('is-pending');
        box.append(overlay('download', () => ensure(msg, 'full'), m, msg));
    }
    if (badge) box.append(badge);
    const p = progress(m);
    if (p) box.append(p);
    return box;
}

/**
 * A video inside an album: a still frame with a badge, never a player.
 *
 * Six <video controls> in one bubble is what the grid used to be - six
 * scrubbers, each one letterboxed inside its cell. The original client
 * shows a frame and opens the viewer on click, and so does this; the
 * viewer is also the only place where a video gets the whole window
 * instead of a sixth of a bubble.
 */
function renderVideoCell(msg, m, group) {
    const box = el('div', {class: `${sizedBox('video', m)} is-clickable`});
    const still = el('img', {
        class: m.thumbUrl ? 'media__img' : 'media__img is-placeholder',
        src: m.thumbUrl || m.thumb || '',
        alt: '',
        loading: 'lazy',
    });
    if (m.thumbUrl) holdImage(still, m.thumbUrl, m.thumb);
    box.append(still);
    // The badge says what the click will do: play what is here, or
    // fetch what is not.
    let glyph = m.url ? 'play' : 'download';
    if (m.xfer) glyph = 'close';
    box.append(addRing(el('span', {class: 'media__play'}, icon(glyph)), m.xfer));
    if (m.duration) {
        box.append(el('span', {class: 'media__badge', textContent: duration(m.duration)}));
    }
    box.addEventListener('click', () => {
        if (m.xfer) cancelTransfer(msg);
        else if (m.url) emit('ui:view', {msg, group});
        else ensure(msg, 'full');
    });
    const p = progress(m);
    if (p) box.append(p);
    return box;
}

function renderAnimation(msg, m) {
    const wrapper = el('div', {class: 'media--gif__wrapper'})
    const box = el('div', {class: sizedBox('gif', m)});
    if (m.url) {
        // Telegram "GIFs" are silent MP4s, which is why this is a <video>
        // and not an <img> - same fact the native side relies on.
        const reused = takeVideo(m.url);
        const player = reused ?? el('video', {
            class: 'media__video',
            src: m.url,
            dataset: {media: m.url},
            // The blurred stamp, for the moments there is no frame to
            // show: before the first one decodes, while the player is
            // released off screen (util/offscreen.js), and now also
            // whenever it is simply not on screen. A poster is an
            // attribute, so dropping the source does not take it.
            poster: m.thumb || '',
            loop: true, muted: true, playsInline: true,
            onclick: () => {
                player.currentTime = 0;
                player.play().catch(() => {
                });
            },
        });
        // "Autoplay GIFs" is off (Battery and animation) — it plays only on
        // a click, the observer does not start it.
        if (!reused) holdVideo(player, m.url, getPref('autoplayGifs') ? 'loop' : false);
        box.append(player);
        if (m.xfer) box.append(xferOverlay(msg, m));
        wrapper.append(box);
    } else {
        box.append(el('img', {
            class: m.thumb ? 'media__img' : 'media__img is-placeholder',
            src: m.thumb || '', alt: '', loading: 'lazy',
        }));
        box.classList.add('is-pending');
        box.append(overlay('download', () => ensure(msg, 'full'), m, msg));
        box.append(el('span', {class: 'media__badge', textContent: 'GIF'}));
    }
    const p = progress(m);
    if (p) box.append(p);
    return m.url ? wrapper : box;
}

// ------------------------------------------------- audio and voice
// One player at a time, the way the native window does it: TMsgScroller
// keeps a single TAudioPlayer for the whole history, so a second track
// starting stops the first.
let playing = null;

/**
 * The card an audio message and a voice note share, following
 * TAudioWidget: a 48px cover, a play/pause button, the title, a
 * progress bar, and the two times - elapsed on the left, what is left
 * as a negative on the right.
 *
 * The <audio> element does the playing but is never shown. Its default
 * controls look nothing like the native widget, and they were also the
 * thing dropping a raw player into the middle of a filtered history.
 *
 * The bar is a <progress> ON PURPOSE: its position is an ATTRIBUTE, so
 * it can move smoothly without anything writing the style attribute -
 * the class ladder that covers the rest of the app only steps in fives.
 */
function audioCard(msg, m, coverIcon, title) {
    const box = el('div', {class: 'media media--audio'});

    const cover = el('div', {class: 'audio__cover'});
    if (m.coverUrl) cover.append(el('img', {src: m.coverUrl, alt: ''}));
    else cover.append(icon(coverIcon));
    box.append(cover);

    const glyph = el('span', {class: 'audio__glyph'});
    const setGlyph = (name) => {
        clear(glyph);
        glyph.append(icon(name));
    };
    const button = el('button', {class: 'audio__play', type: 'button'}, glyph);
    box.append(button);

    const total = Number(m.duration) || 0;
    const track = el('progress', {class: 'audio__track', max: 1, value: 0});
    const elapsed = el('span', {textContent: signedDuration(0)});
    const remaining = el('span', {textContent: signedDuration(-total)});
    box.append(el('div', {class: 'audio__body'},
        el('div', {class: 'audio__title', textContent: title}),
        track,
        el('div', {class: 'audio__times'}, elapsed, remaining)));

    // The ring — around the button, "how much of how much" and "how much is
    // left" — in place of the two times: while the file is not here, there is nothing to play.
    if (m.xfer) {
        addRing(button, m.xfer);
        elapsed.textContent = xferText(m.xfer);
        remaining.textContent = xferLeft(m.xfer);
        // The button only cancels: the download is running already, and
        // there is no point playing one's own half-sent file.
        setGlyph('close');
        button.title = 'Cancel';
        track.classList.add('is-idle');
        button.addEventListener('click', () => cancelTransfer(msg));
        return box;
    }

    if (!m.url) {
        setGlyph('download');
        button.title = 'Download';
        track.classList.add('is-idle');
        button.addEventListener('click', () => ensure(msg, 'full'));
        return box;
    }

    setGlyph('play');
    button.title = 'Play';
    const sound = el('audio', {src: m.url, preload: 'none', hidden: true});
    box.append(sound);

    // The file's own duration once it is known: TDLib's is rounded to
    // whole seconds, and seeking off a rounded length drifts.
    const length = () => (sound.duration > 0 && Number.isFinite(sound.duration)
        ? sound.duration : total);

    button.addEventListener('click', () => {
        if (!sound.paused) {
            sound.pause();
            return;
        }
        if (playing && playing !== sound) playing.pause();
        playing = sound;
        sound.play().catch(() => {
        });
    });
    sound.addEventListener('play', () => {
        setGlyph('pause');
        button.title = 'Pause';
    });
    sound.addEventListener('pause', () => {
        setGlyph('play');
        button.title = 'Play';
    });
    sound.addEventListener('timeupdate', () => {
        const len = length();
        track.value = len > 0 ? Math.min(1, sound.currentTime / len) : 0;
        elapsed.textContent = signedDuration(sound.currentTime);
        remaining.textContent = signedDuration(sound.currentTime - len);
    });
    sound.addEventListener('ended', () => {
        track.value = 0;
        elapsed.textContent = signedDuration(0);
        remaining.textContent = signedDuration(-length());
    });
    track.addEventListener('click', (e) => {
        const len = length();
        if (len <= 0) return;
        const box = track.getBoundingClientRect();
        const at = (e.clientX - box.left) / box.width;
        sound.currentTime = Math.min(len, Math.max(0, at * len));
    });

    return box;
}

function renderAudio(msg, m) {
    // Performer and title joined, whichever one exists, the file name
    // when there is no metadata at all - TAudioWidget.Paint's own rule.
    const title = [m.performer, m.title].filter(Boolean).join(' - ')
        || m.fileName || 'Audio';
    return audioCard(msg, m, 'audio', title);
}

// Voice message transcription (recognizeSpeech) — Premium only: without it
// Telegram answers with an error, so there is no button at all. The flag
// comes with every messages.list answer (canTranscribe), main.js puts it here.
let canTranscribe = false;

/** true — the flag changed (voice messages already drawn need a redraw). */
export function setCanTranscribe(value) {
    const changed = canTranscribe !== !!value;
    canTranscribe = !!value;
    return changed;
}

// Folded transcriptions (message ids): folding is a class on the node,
// without a redraw; remembered so a redraw does not unfold them.
const speechFolded = new Set();

function renderVoice(msg, m) {
    // A voice note never has a cover or a title: the native side passes
    // this very label as the file name and shows the microphone frame.
    const card = audioCard(msg, m, 'mic', 'Voice message');
    const sp = m.speech;
    if (!canTranscribe && !sp) return card;

    const text = sp ? el('div', {
        class: `voice__speech${sp.state === 'error' ? ' is-error' : ''}${sp.state === 'pending' ? ' is-pending' : ''}`,
        hidden: speechFolded.has(msg.id),
    }, sp.state === 'error'
        ? (sp.text || 'Could not transcribe this message')
        : `${sp.text || ''}${sp.state === 'pending' ? '\u2026' : ''}`) : null;

    // The button — in the top right corner of the card, in a "frame": a div
    // with a 2px padding, the button inside it. The frame is the canvas for
    // the animation: while Telegram recognizes (pending or just pressed), a
    // spot of radial gradient runs along it (blocks/_media.scss, voice-tx-orbit).
    if (canTranscribe) {
        const folded = speechFolded.has(msg.id);
        const frame = el('div', {
            class: `voice__tx${sp && sp.state !== 'pending' && !folded ? ' is-on' : ''}`
                + `${sp?.state === 'pending' ? ' is-busy' : ''}`,
        });
        const button = el('button', {
            class: 'voice__tx-btn',
            type: 'button',
            title: sp ? 'Show or hide the text' : 'Transcribe to text',
            onclick: (event) => {
                event.stopPropagation();
                if (!sp) {
                    frame.classList.add('is-busy');
                    emit('ui:transcribe', {id: msg.id});
                    return;
                }
                const fold = !speechFolded.has(msg.id);
                if (fold) speechFolded.add(msg.id);
                else speechFolded.delete(msg.id);
                if (text) text.hidden = fold;
                frame.classList.toggle('is-on', !fold && sp.state !== 'pending');
            },
        }, icon('transcribe', 'voice__tx-icon'));
        frame.append(button);
        card.classList.add('has-tx');
        card.append(frame);
    }

    return text ? el('div', {class: 'voice'}, card, text) : card;
}

/**
 * A document, following TFileWidget: the icon on the left is the file
 * type once the file is here and a download arrow until then, the name
 * sits where audio's title does and the size where its times do, and
 * the whole card is the click target rather than a button inside it.
 */
function renderFile(msg, m) {
    const name = m.fileName || 'File';
    // While the file is transferred, the whole card is a cancel (as is its ring).
    const box = m.xfer
        ? el('div', {
            class: 'media media--file is-clickable',
            title: 'Cancel',
            onclick: () => cancelTransfer(msg),
        })
        : m.url
        // Open with an external app (util/download.js): the file itself is
        // never shown in the window.
        ? el('a', {
            class: 'media media--file is-clickable',
            href: downloadUrl(m.url, name, true),
            download: name,
            title: 'Open this file',
        })
        : el('div', {
            class: 'media media--file is-clickable',
            title: 'Download this file',
            onclick: () => ensure(msg, 'full'),
        });

    // While the file is transferred — an arrow (up when sending) in the
    // progress ring and "how much of how much · how much is left" in place of the size.
    let glyph = m.url ? 'file' : 'download';
    if (m.xfer) glyph = 'close';
    box.append(addRing(el('span', {class: 'file__icon'}, icon(glyph)), m.xfer));
    box.append(el('div', {class: 'file__body'},
        el('div', {class: 'file__name', textContent: name}),
        el('div', {class: 'file__size u-tabular',
            textContent: m.xfer ? `${xferText(m.xfer)} · ${xferLeft(m.xfer)}` : fileSize(m.size)})));
    return box;
}

/** A sticker outside a message — the greeting of an empty chat (ui/greeting.js). */
export function stickerNode(m) {
    return renderSticker(null, m);
}

function renderSticker(msg, m) {
    const box = el('div', {class: 'media media--sticker'});
    if (!m.url) {
        box.append(el('div', {class: 'media__sticker-wait', textContent: '…'}));
        return box;
    }
    if (m.format === 'webm') {
        // Not autoplay: what starts it is coming into view, and what
        // stops it is leaving - see util/offscreen.js. A click replays
        // it from the start.
        // "Loop animated stickers" — in a loop while on screen; "Animated
        // stickers" off — stays on the first frame until a click (the frame
        // appears only after seeking, see util/emoji.js).
        const looping = getPref('loopStickers');
        const still = !getPref('animatedStickers');
        const reused = takeVideo(m.url);
        const player = reused ?? el('video', {
            class: 'media__sticker',
            src: m.url, loop: looping && !still, muted: true, playsInline: true,
            dataset: {media: m.url},
            onloadeddata: still ? () => {
                try { player.currentTime = 0.01; } catch { /* no data */ }
            } : null,
            onclick: () => {
                player.currentTime = 0;
                player.play().catch(() => {
                });
            },
            // Back to the first frame when it finishes, so a sticker at
            // rest wears its own face.
            onended: () => {
                player.currentTime = 0;
            },
        });
        if (!reused) holdVideo(player, m.url, still ? false : (looping ? 'loop' : 'once'));
        box.append(player);
    } else if (m.format === 'tgs') {
        // A gzip-compressed Lottie animation - see ui/sticker.js, which
        // owns the unpacking, the player and the "is it on screen"
        // question. The frame is created here and filled there, so a
        // sticker that cannot be played says so instead of leaving a
        // hole the size of a sticker.
        const frame = el('div', {class: 'media__sticker media__sticker--lottie'});
        box.append(frame);
        // "Loop animated stickers" (Chat settings) — in a loop; "Animated
        // stickers" off (Battery and animation) — stays until a click.
        playSticker(frame, m.url, {
            once: !getPref('loopStickers'),
            still: !getPref('animatedStickers'),
        }).then((ok) => {
            if (ok || !frame.isConnected) return;
            frame.replaceWith(el('div', {
                class: 'media__sticker-wait',
                textContent: 'animated sticker',
            }));
        });
    } else {
        const face = el('img', {class: 'media__sticker', src: m.url, alt: ''});
        holdImage(face, m.url);
        box.append(face);
    }
    return box;
}

// ------------------------------------------------------------ poll
// ---------------------------------------------------------- contact
/**
 * A contact card: avatar, name, phone. A person on Telegram — a click opens
 * the private chat with them (ui:open-contact, as in the contact list) and
 * there is "Add"; without an account — only copying the phone.
 */
function renderContact(msg) {
    const c = msg.contact;
    const avatar = el('span', {class: `avatar avatar--lg contact-card__avatar accent-${c.color}`});
    fillAvatar(avatar, {id: c.userId, title: c.name || c.phone, avatar: c.avatar, avatarThumb: c.avatarThumb});
    const inTelegram = c.userId && c.userId !== '0';
    const card = el('div', {class: 'contact-card'},
        el('button', {
            class: 'contact-card__main', type: 'button',
            title: inTelegram ? 'Open the chat' : 'Copy the phone number',
            onclick: async () => {
                if (inTelegram) {
                    emit('ui:open-contact', {userId: c.userId});
                } else if (c.phone) {
                    await copyText(`+${c.phone.replace(/^\+/, '')}`);
                }
            },
        },
        avatar,
        el('span', {class: 'contact-card__text'},
            el('span', {class: 'contact-card__name'}, c.name || 'Contact'),
            c.phone ? el('span', {class: 'contact-card__phone u-tabular'},
                `+${c.phone.replace(/^\+/, '')}`) : null)));
    if (inTelegram) {
        card.append(el('div', {class: 'contact-card__buttons'},
            el('button', {
                class: 'btn contact-card__button', type: 'button',
                onclick: () => emit('ui:open-contact', {userId: c.userId}),
            }, 'Message'),
            el('button', {
                class: 'btn contact-card__button', type: 'button',
                onclick: () => emit('ui:add-contact', {userId: c.userId, first: c.first, last: c.last}),
            }, 'Add contact')));
    }
    return card;
}

// ------------------------------------------------------------- call
/**
 * A call in the history (messageCall / messageGroupCall, webapi.pas
 * CallMessageJson): an icon, what kind of call, the duration or how it
 * ended, and a button — call back the same way (ui:call-back, ui/call.js)
 * or join the running video chat (ui:vchat-join).
 */
const CALL_REASON = {
    missed: 'Missed',
    declined: 'Declined',
    disconnected: 'Disconnected',
};

function renderCall(msg) {
    const c = msg.call;
    const kind = c.video ? 'video call' : 'call';
    let title;
    let failed = false;
    if (c.group) {
        title = c.reason === 'active' ? 'Ongoing group call' : (c.reason === 'missed' ? 'Missed group call' : 'Group call');
        failed = c.reason === 'missed';
    } else if (c.reason === 'missed' || c.reason === 'declined') {
        // One's own unanswered — "cancelled", someone else's — "missed".
        title = msg.outgoing
            ? (c.reason === 'declined' ? `Declined ${kind}` : `Cancelled ${kind}`)
            : `Missed ${kind}`;
        failed = true;
    } else {
        title = `${msg.outgoing ? 'Outgoing' : 'Incoming'} ${kind}`;
    }
    const sub = c.duration > 0
        ? duration(c.duration)
        : (CALL_REASON[c.reason] ?? (c.reason === 'active' ? 'In progress' : ''));
    const again = c.group
        ? (c.reason === 'active'
            ? el('button', {
                class: 'btn call-card__button', type: 'button',
                onclick: () => emit('ui:vchat-join'),
            }, 'Join')
            : null)
        : el('button', {
            class: 'call-card__again', type: 'button',
            title: c.video ? 'Video call again' : 'Call again',
            onclick: () => emit('ui:call-back', {video: !!c.video}),
        }, icon(c.video ? 'video' : 'mic'));
    return el('div', {class: `call-card${failed ? ' is-failed' : ''}${msg.outgoing ? ' is-outgoing' : ''}`},
        el('span', {class: 'call-card__icon'}, icon(c.video ? 'video' : 'mic')),
        el('span', {class: 'call-card__text'},
            el('span', {class: 'call-card__title'}, title),
            sub ? el('span', {class: 'call-card__sub u-tabular'}, sub) : null),
        again);
}

// --------------------------------------------------------- location
/**
 * A location, a place (venue) or a live location: a Telegram map with a
 * pin in the centre, below it the name and address of the place. A click —
 * the point in the chosen map service in the browser (util/maps.js).
 */
function renderLocation(msg) {
    const l = msg.location;
    const url = mapUrl(l.lat, l.lon);
    const info = [];
    if (l.title) info.push(el('span', {class: 'location__title'}, l.title));
    if (l.address) info.push(el('span', {class: 'location__address'}, l.address));
    // A plain location has no text — content has only the coordinates and
    // the accuracy (a live log); those are what we label. No address is looked
    // up by coordinates: that would mean sending them to a third-party service.
    if (!l.title && !l.address) {
        const acc = l.accuracy > 0 ? ` · ±${Math.round(l.accuracy)} m` : '';
        info.push(el('span', {class: 'location__address u-tabular'},
            `${Number(l.lat).toFixed(6)}, ${Number(l.lon).toFixed(6)}${acc}`));
    }
    if (l.live) {
        info.push(el('span', {class: 'location__live'},
            l.expiresIn > 0 ? 'Live location' : 'Live location ended'));
    }
    return el('button', {
        class: 'location', type: 'button', title: 'Open the map',
        // The map service — the default from the settings or from the choice window.
        onclick: () => openMapPoint(l.lat, l.lon),
    },
    el('span', {class: `location__map${url ? '' : ' is-pending'}`},
        url ? el('img', {class: 'location__img', src: url, alt: ''}) : null,
        el('span', {class: 'location__pin'})),
    info.length ? el('span', {class: 'location__info'}, ...info) : null);
}

function renderPoll(msg) {
    const p = msg.poll;
    const box = el('div', {class: `poll${p.multiple ? ' poll--multiple' : ''}`});
    box.append(el('div', {class: 'poll__question', textContent: p.question}));
    box.append(el('div', {
        class: 'poll__kind',
        textContent: [
            p.anonymous ? 'Anonymous poll' : 'Public poll',
            p.quiz ? 'quiz' : null,
            p.multiple ? 'multiple answers' : null,
            p.closed ? 'closed' : null,
        ].filter(Boolean).join(' · '),
    }));

    // Once answered (or closed) the percentages are shown; before that
    // the options are just choices. Same split as the native widget.
    const answered = p.closed || p.options.some((o) => o.chosen);

    p.options.forEach((opt, index) => {
        const row = el('button', {
            class: [
                'poll__option',
                opt.chosen ? 'is-chosen' : '',
                p.quiz && answered && index === p.correctOption ? 'is-correct' : '',
                p.quiz && answered && opt.chosen && index !== p.correctOption ? 'is-wrong' : '',
            ].filter(Boolean).join(' '),
            type: 'button',
            disabled: p.closed || (answered && !p.revoting && !p.multiple),
            onclick: () => emit('ui:vote', {id: msg.id, option: index}),
        });
        row.append(el('span', {class: 'poll__mark'}));
        row.append(el('span', {class: 'poll__text', textContent: opt.text}));
        if (answered) {
            row.append(el('span', {class: 'poll__pct', textContent: `${opt.percentage}%`}));
            row.append(el('span', {
                class: `poll__bar w-${Math.round(opt.percentage / 5) * 5}`,
            }));
        }
        box.append(row);
    });

    box.append(el('div', {
        class: 'poll__total',
        textContent: p.totalVoters === 1 ? '1 vote' : `${p.totalVoters} votes`,
    }));
    return box;
}

// ------------------------------------------------------- reactions
/**
 * The strip under a message: reactions on the left, the comments pill
 * on the right.
 *
 * One row rather than two, because a post can have either, both or
 * neither - and when it has both they belong on the same line, which
 * is where the original client puts them.
 */
function renderFooter(msg, commentsMoved = false) {
    const hasReactions = !!msg.reactions?.length;
    // A channel post: even at zero — nobody has commented yet, and the
    // button is the only way to leave the first comment. Elsewhere (a
    // group sends a reply count with every message) only when there are
    // replies: a "0" under every message is noise. Unless the button has
    // gone into the head instead - see renderMessage.
    const hasComments = !commentsMoved && msg.comments !== undefined
        && (msg.comments > 0 || inChannelFeed());
    if (!hasReactions && !hasComments) return null;

    const strip = el('footer', {class: 'message__reactions'});
    if (hasReactions) fillReactions(strip, msg);
    if (hasComments) {
        // Pushed to the far edge whether or not anything precedes it.
        strip.append(el('span', {class: 'message__reactions-gap'}));
        strip.append(renderComments(msg));
    }
    return strip;
}

/** The open history is a channel's own feed (not a comment thread under a post). */
function inChannelFeed() {
    return store.activeChat?.kind === 'channel' && !openThread();
}

/**
 * "N comments", shaped like a reaction pill and sitting at the right
 * edge of the same strip.
 *
 * The count is message.interaction_info.reply_info.reply_count: the
 * comments of a channel post with a discussion group, and in a
 * supergroup the replies to any message (renderFooter shows those only
 * when there are some).
 */
function renderComments(msg) {
    const pill = el('button', {
        class: `comments${msg.commentsNew ? ' is-unread' : ''}`,
        type: 'button',
        title: msg.comments ? 'Comments' : 'Leave a comment',
        onclick: () => emit('ui:comments', {msg}),
    });
    pill.append(icon('chat', 'comments__icon'));
    pill.append(el('span', {class: 'comments__count', textContent: String(msg.comments)}));
    return pill;
}

function fillReactions(strip, msg) {
    for (const r of msg.reactions) {
        // A plain emoji reaction is a button: clicking it adds this
        // account's own, clicking it again takes it away. The other two
        // kinds are not, because there is nothing to toggle - a paid
        // reaction costs stars and a custom one is a Premium sticker
        // this page cannot offer yet.
        const clickable = r.kind === 'emoji';
        // The hint — in aria-label, not title: on hover a list of those who
        // reacted pops up, and a native tooltip would lie on top of it.
        const pill = el(clickable ? 'button' : 'span', {
            class: `reaction${r.chosen ? ' is-chosen' : ''}`,
            type: clickable ? 'button' : null,
            'aria-label': clickable
                ? (r.chosen ? 'Remove this reaction' : 'React with this')
                : null,
            onclick: clickable
                ? () => emit('ui:react', {msg, emoji: r.emoji})
                : null,
        });
        if (r.kind === 'emoji') {
            pill.append(el('span', {class: 'reaction__emoji', textContent: r.emoji}));
        } else if (r.kind === 'paid') {
            pill.append(el('span', {class: 'reaction__emoji', textContent: '★'}));
        } else {
            // A Premium custom emoji: the same sticker, from the same
            // per-response dictionary, as one sitting inside a line of
            // text. Its file may not have arrived yet, and then there is
            // no glyph to fall back on the way text has one - a dot
            // holds the place until it does.
            pill.append(customEmojiNode(r.customEmojiId, 'reaction__emoji')
                ?? el('span', {class: 'reaction__emoji', textContent: '•'}));
        }
        pill.append(String(r.count));
        // Who reacted — for all but paid ones: Telegram does not give their
        // list (getMessageAddedReactions, td_api.tl).
        // And only where Telegram gives it at all (can_get_added_reactions —
        // comes with the message itself, without a request): otherwise hover
        // does nothing.
        if (!msg.canSeeReactors) {
            // no list is offered
        } else if (r.kind === 'emoji') {
            peopleOnHover(pill, {id: String(msg.id), what: 'reactions', emoji: r.emoji}, 'Reacted');
        } else if (r.kind !== 'paid' && r.customEmojiId) {
            peopleOnHover(pill, {id: String(msg.id), what: 'reactions',
                customEmojiId: String(r.customEmojiId)}, 'Reacted');
        }
        strip.append(pill);
    }
}
