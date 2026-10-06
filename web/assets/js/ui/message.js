import {el, clear} from '../core/dom.js';
import {emit} from '../core/bus.js';
import {icon} from '../util/icons.js';
import {playSticker} from './sticker.js';
import {customEmojiNode} from '../util/emoji.js';
import {renderRichText} from '../util/entities.js';
import {holdImage, holdVideo} from '../util/offscreen.js';
import {clockTime, fileSize, duration, signedDuration} from '../util/format.js';
import {addRing, xferText, xferLeft} from '../util/xfer.js';
import {peopleOnHover} from './people.js';
import {renderInlineKeyboard} from './bots.js';
import {mapUrl, openMapPoint} from '../util/maps.js';
import {fillAvatar} from '../util/avatar.js';
import {copyText} from '../util/clipboard.js';
import {translationFor, watchTranslation} from './translate.js';

// One message block, following framehistory.pas rather than inventing a
// second visual language: a tinted header line (status mark, sender,
// time) over the body, the whole card carrying the sender's accent, and
// reactions as a strip along the bottom.
//
// Own messages are NOT mirrored to the right. That is the native
// window's arrangement - a dense single column where the sender colour
// already tells the two apart - and matching it is the point.

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

// Плееры прежнего узла того же сообщения, по адресу файла. Сообщение
// перестраивается целиком при любой смене своего payload (реакции,
// счётчик комментариев, ход передачи — живой лог: в одном канале 28
// смен реакций за 9 минут), и новый <video> заново тянул файл — на
// незапущенном видео мелькал нативный индикатор загрузки, а играющее
// останавливалось. Теперь тот же элемент переносится в новый узел:
// перенос в одном задании воспроизведение не прерывает (элемент не
// успевает оказаться вне документа к «стабильному состоянию»).
let reusable = null;

/**
 * Как renderMessage, но видео с тем же адресом берутся из `oldNode`, а не
 * создаются заново. Адрес — data-media: src плеер теряет, когда уходит за
 * экран (util/offscreen.js отпускает декодер).
 */
export function renderMessageReusing(msg, oldNode) {
    // Узел вне документа мог уже пройти через sweep (util/offscreen.js):
    // его плееры без src и без наблюдателей, переносить их нельзя.
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

/** Плеер прежнего узла для этого адреса, или null — тогда строить новый. */
function takeVideo(url) {
    const video = reusable?.get(url) ?? null;
    if (video) reusable.delete(url);
    return video;
}

export function renderMessage(msg) {
    // Сервисное сообщение (создание группы, вход, закреп…) — строка
    // посередине истории, без пузыря и заголовка.
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
            msg.kind === 'sticker' ? 'message--sticker' : '',
        ].filter(Boolean).join(' '),
        dataset: {messageId: String(msg.id)},
    });

    // A sticker has no bubble, so a strip under it is a bar of its own
    // across the history - worth it for reactions, absurd for a
    // comments button reading zero. On a sticker the button moves up
    // into the head, where there is room going spare, and only once
    // there is something to count.
    const bare = msg.kind === 'sticker';
    card.append(renderHead(msg, bare && msg.comments > 0));
    if (msg.reply) card.append(renderReply(msg));
    if (msg.forward) card.append(renderForward(msg));

    const body = el('div', {class: 'message__body'});
    const media = renderMedia(msg);
    if (media) body.append(media);
    if (msg.kind === 'poll' && msg.poll) body.append(renderPoll(msg));
    if (msg.kind === 'location' && msg.location) body.append(renderLocation(msg));
    if (msg.kind === 'contact' && msg.contact) body.append(renderContact(msg));
    // Перевод чата включён и готов — он вместо текста (ui/translate.js).
    const tr = translationFor(msg);
    if (msg.text) body.append(renderRichText(tr ? tr.text : msg.text, tr ? tr.entities : (msg.entities ?? [])));
    if (tr) body.append(el('div', {class: 'message__translated'}, 'Translated'));
    if (msg.link) body.append(renderLinkPreview(msg));
    if (body.childNodes.length) card.append(body);

    const footer = renderFooter(msg, bare);
    if (footer) card.append(footer);
    watchTranslation(card, msg);
    // Кнопки бота под сообщением (ui/bots.js).
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
    const footed = msgs.find((m) => m.reactions?.length || m.comments !== undefined);
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
        // Наведение — кто прочитал (ui/people.js). Обёртка нужна: у
        // самой иконки pointer-events: none.
        const hit = el('span', {class: 'message__receipt-hit'}, icon(receipt, 'message__receipt'));
        peopleOnHover(hit, {id: String(msg.id), what: 'viewers'}, 'Seen by');
        head.append(hit);
    }

    // Аватарка отправителя перед именем.
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
 * Клик по кольцу: скачивание останавливается, исходящее удаляется, как
 * у нативного клиента (TTdMessages.CancelTransfer). Пока передача идёт,
 * в кольце крестик — так видно, что клик отменит, а не скачает.
 */
function cancelTransfer(msg) {
    emit('ui:cancel-transfer', {id: msg.id});
}

/**
 * «Сколько из скольких» в углу картинки, пока файл передаётся (вниз или
 * вверх), или ничего. Само кольцо — на кнопке посередине (overlay /
 * xferOverlay); раньше здесь была линейная полоска только для фото и
 * видео и только на скачивание.
 */
function progress(m) {
    if (!m.xfer) return null;
    return el('span', {class: 'media__xfer u-tabular', textContent: xferText(m.xfer)});
}

/**
 * Кольцо поверх картинки, у которой файл уже есть, но ещё уходит —
 * исходящее фото, видео, GIF. Клик отменяет отправку; дальше по
 * картинке (просмотрщик) он не идёт.
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
    // Пока файл качается — кольцо хода вокруг кнопки и крестик в нём:
    // клик отменяет загрузку.
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
        if (!reused) holdVideo(player, m.url, 'loop');
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

    // Кольцо — вокруг кнопки, «сколько из скольких» и «сколько осталось» —
    // на месте двух времён: пока файл не здесь, проигрывать нечего.
    if (m.xfer) {
        addRing(button, m.xfer);
        elapsed.textContent = xferText(m.xfer);
        remaining.textContent = xferLeft(m.xfer);
        // Кнопка только отменяет: качать уже качается, а играть свой
        // недоотправленный файл незачем.
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

function renderVoice(msg, m) {
    // A voice note never has a cover or a title: the native side passes
    // this very label as the file name and shows the microphone frame.
    return audioCard(msg, m, 'mic', 'Voice message');
}

/**
 * A document, following TFileWidget: the icon on the left is the file
 * type once the file is here and a download arrow until then, the name
 * sits where audio's title does and the size where its times do, and
 * the whole card is the click target rather than a button inside it.
 */
function renderFile(msg, m) {
    const name = m.fileName || 'File';
    // Пока файл передаётся, вся карточка — отмена (как и её кольцо).
    const box = m.xfer
        ? el('div', {
            class: 'media media--file is-clickable',
            title: 'Cancel',
            onclick: () => cancelTransfer(msg),
        })
        : m.url
        ? el('a', {
            class: 'media media--file is-clickable',
            href: m.url,
            download: name,
            title: 'Save this file',
        })
        : el('div', {
            class: 'media media--file is-clickable',
            title: 'Download this file',
            onclick: () => ensure(msg, 'full'),
        });

    // Пока файл передаётся — стрелка (вверх при отправке) в кольце хода и
    // «сколько из скольких · сколько осталось» на месте размера.
    let glyph = m.url ? 'file' : 'download';
    if (m.xfer) glyph = 'close';
    box.append(addRing(el('span', {class: 'file__icon'}, icon(glyph)), m.xfer));
    box.append(el('div', {class: 'file__body'},
        el('div', {class: 'file__name', textContent: name}),
        el('div', {class: 'file__size u-tabular',
            textContent: m.xfer ? `${xferText(m.xfer)} · ${xferLeft(m.xfer)}` : fileSize(m.size)})));
    return box;
}

/** Стикер вне сообщения — приветствие пустого чата (ui/greeting.js). */
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
        const reused = takeVideo(m.url);
        const player = reused ?? el('video', {
            class: 'media__sticker',
            src: m.url, loop: false, muted: true, playsInline: true,
            dataset: {media: m.url},
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
        if (!reused) holdVideo(player, m.url, 'once');
        box.append(player);
    } else if (m.format === 'tgs') {
        // A gzip-compressed Lottie animation - see ui/sticker.js, which
        // owns the unpacking, the player and the "is it on screen"
        // question. The frame is created here and filled there, so a
        // sticker that cannot be played says so instead of leaving a
        // hole the size of a sticker.
        const frame = el('div', {class: 'media__sticker media__sticker--lottie'});
        box.append(frame);
        playSticker(frame, m.url, {once: true}).then((ok) => {
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
 * Карточка контакта: аватарка, имя, телефон. Человек в Telegram — клик
 * открывает личку с ним (ui:open-contact, как в списке контактов) и
 * есть «Add»; без аккаунта — только копирование телефона.
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

// --------------------------------------------------------- location
/**
 * Геопозиция, место (venue) или трансляция геопозиции: карта Telegram с
 * меткой по центру, под ней — название и адрес места. Клик — точка в
 * выбранном сервисе карт в браузере (util/maps.js).
 */
function renderLocation(msg) {
    const l = msg.location;
    const url = mapUrl(l.lat, l.lon);
    const info = [];
    if (l.title) info.push(el('span', {class: 'location__title'}, l.title));
    if (l.address) info.push(el('span', {class: 'location__address'}, l.address));
    // У простой геопозиции текста нет — в content только координаты и
    // точность (живой лог); их и подписываем. Адрес по координатам не
    // ищется: для этого их пришлось бы отправить стороннему сервису.
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
        // Сервис карт — по умолчанию из настроек или из окна выбора.
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
    // Not "> 0": a post nobody has commented on still shows the
    // button, and that button is the only way to leave the first one.
    // Unless it has gone into the head instead - see renderMessage.
    const hasComments = !commentsMoved && msg.comments !== undefined;
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

/**
 * "N comments", shaped like a reaction pill and sitting at the right
 * edge of the same strip.
 *
 * The count is message.interaction_info.reply_info.reply_count, which
 * TDLib fills only for channels that have a discussion supergroup - so
 * the pill appears exactly where comments exist.
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
        // Подсказка — в aria-label, а не title: по наведению всплывает
        // список тех, кто поставил реакцию, и нативная подсказка легла
        // бы поверх него.
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
        // Кто поставил — у всех, кроме платных: их список Telegram не
        // отдаёт (getMessageAddedReactions, td_api.tl).
        // И только там, где Telegram его вообще отдаёт
        // (can_get_added_reactions — приходит с самим сообщением, без
        // запроса): иначе наведение ничего не делает.
        if (!msg.canSeeReactors) {
            // список не предлагается
        } else if (r.kind === 'emoji') {
            peopleOnHover(pill, {id: String(msg.id), what: 'reactions', emoji: r.emoji}, 'Reacted');
        } else if (r.kind !== 'paid' && r.customEmojiId) {
            peopleOnHover(pill, {id: String(msg.id), what: 'reactions',
                customEmojiId: String(r.customEmojiId)}, 'Reacted');
        }
        strip.append(pill);
    }
}
