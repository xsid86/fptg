import {el} from '../core/dom.js';
import {emit} from '../core/bus.js';
import {icon} from '../util/icons.js';
import {renderRichText} from '../util/entities.js';
import {clockTime, fileSize, duration} from '../util/format.js';

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

const KIND_ICON = {
    photo: 'image',
    video: 'video',
    animation: 'gif',
    audio: 'audio',
    voice: 'mic',
    file: 'file',
    poll: 'poll',
    sticker: 'smile',
};

export function renderMessage(msg) {
    const card = el('article', {
        class: [
            'message',
            `accent-${msg.senderColor}`,
            msg.outgoing ? 'message--outgoing' : '',
            msg.kind === 'sticker' ? 'message--sticker' : '',
        ].filter(Boolean).join(' '),
        dataset: {messageId: String(msg.id)},
    });

    card.append(renderHead(msg));
    if (msg.reply) card.append(renderReply(msg));
    if (msg.forward) card.append(renderForward(msg));

    const body = el('div', {class: 'message__body'});
    const media = renderMedia(msg);
    if (media) body.append(media);
    if (msg.kind === 'poll' && msg.poll) body.append(renderPoll(msg));
    if (msg.text) body.append(renderRichText(msg.text, msg.entities ?? []));
    if (body.childNodes.length) card.append(body);

    if (msg.reactions?.length) card.append(renderReactions(msg));
    return card;
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
    if (captioned) body.append(renderRichText(captioned.text, captioned.entities ?? []));
    card.append(body);

    const reacted = msgs.find((m) => m.reactions?.length);
    if (reacted) card.append(renderReactions(reacted));
    return card;
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
function renderHead(msg) {
    const head = el('header', {class: 'message__head'});

    const receipt = RECEIPT_ICON[msg.receipt];
    if (receipt) head.append(icon(receipt, 'message__receipt'));
    else if (KIND_ICON[msg.kind]) head.append(icon(KIND_ICON[msg.kind], 'message__receipt'));

    head.append(el('span', {
        class: 'message__sender',
        textContent: msg.senderName || (msg.outgoing ? 'You' : 'Unknown'),
    }));
    head.append(el('span', {class: 'message__time', textContent: clockTime(msg.date)}));
    if (msg.editDate) {
        head.append(el('span', {class: 'message__state', textContent: 'edited'}));
    }
    return head;
}

// ------------------------------------------------------------ reply
function renderReply(msg) {
    const banner = el('button', {
        class: `message__reply accent-${msg.reply.color ?? msg.senderColor}`,
        type: 'button',
        onclick: () => emit('ui:jump', msg.reply.id),
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

/**
 * The classes for one media box: the block, and - when the size is
 * known - the rung of the ratio ladder that gives the box the shape of
 * what is inside it.
 *
 * Without the ratio the box is sized by the original's width and ends
 * up wider than the capped picture, which is what used to show as a
 * grey margin beside every landscape photo. See .media--sized in
 * blocks/_media.scss for why the cap alone cannot fix that.
 */
function sizedBox(kind, m) {
    const base = `media media--${kind}`;
    if (!(m.w > 0 && m.h > 0)) return base;
    return `${base} media--sized media--ar-${clamp(Math.round((m.w / m.h) * 20) * 5, 40, 400)}`;
}

function ensure(msg, what) {
    emit('ui:ensure-media', {id: msg.id, what});
}

/** A progress line for a download in flight, or nothing. */
function progress(m) {
    if (!m.total || m.got >= m.total) return null;
    const bar = el('div', {class: 'media__progress'},
        el('div', {class: `media__progress-fill w-${Math.round((m.got / m.total) * 20) * 5}`}));
    return bar;
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
    box.append(img);
    if (m.url) {
        box.classList.add('is-clickable');
        box.addEventListener('click', () => emit('ui:view', {msg, group}));
    } else {
        box.append(el('button', {
            class: 'media__action', type: 'button',
            onclick: () => ensure(msg, 'preview'),
        }, icon('image'), 'Load photo'));
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
        box.append(el('video', {
            class: 'media__video',
            src: m.url,
            poster: m.thumbUrl || '',
            controls: true,
            preload: 'metadata',
        }));
    } else {
        box.append(el('img', {
            class: m.thumbUrl ? 'media__img' : 'media__img is-placeholder',
            src: m.thumbUrl || '',
            alt: '',
            loading: 'lazy',
        }));
        let button = el('button', {
            class: 'media__action',
            type: 'button', onclick: () => ensure(msg, 'full'),
        }, icon('video'));
        let button_text = el('span');
        button_text.innerText = duration(m.duration);
        button.append(button_text);
        box.append(button);
    }
    const p = progress(m);
    if (p) box.append(p);
    boxWrapper.append(box);
    return boxWrapper;
}

/**
 * A video inside an album: a still frame with a play badge, never a
 * player.
 *
 * Six <video controls> in one bubble is what the grid used to be - six
 * scrubbers, each one letterboxed inside its cell. The original client
 * shows a frame and opens the viewer on click, and so does this; the
 * viewer is also the only place where a video gets the whole window
 * instead of a sixth of a bubble.
 */
function renderVideoCell(msg, m, group) {
    const box = el('div', {class: `${sizedBox('video', m)} is-clickable`});
    box.append(el('img', {
        class: m.thumbUrl ? 'media__img' : 'media__img is-placeholder',
        src: m.thumbUrl || m.thumb || '',
        alt: '',
        loading: 'lazy',
    }));
    box.append(el('span', {class: 'media__play'}, icon('play')));
    if (m.duration) {
        box.append(el('span', {class: 'media__badge', textContent: duration(m.duration)}));
    }
    // Downloaded: the viewer plays it. Not yet: the same click starts
    // the download, which is the only thing that could happen next.
    box.addEventListener('click', () => {
        if (m.url) emit('ui:view', {msg, group});
        else ensure(msg, 'full');
    });
    const p = progress(m);
    if (p) box.append(p);
    return box;
}

function renderAnimation(msg, m) {
    const box = el('div', {class: sizedBox('gif', m)});
    if (m.url) {
        // Telegram "GIFs" are silent MP4s, which is why this is a <video>
        // and not an <img> - same fact the native side relies on.
        box.append(el('video', {
            class: 'media__video',
            src: m.url,
            autoplay: true, loop: true, muted: true, playsInline: true,
        }));
    } else {
        box.append(el('img', {
            class: 'media__img is-placeholder', src: m.thumb || '', alt: '', loading: 'lazy',
        }));
        box.append(el('button', {
            class: 'media__action', type: 'button',
            onclick: () => ensure(msg, 'full'),
        }, icon('gif'), 'Load GIF'));
    }
    return box;
}

function renderAudio(msg, m) {
    const box = el('div', {class: 'media media--audio'});
    const cover = el('div', {class: 'media__cover'});
    if (m.coverUrl) cover.append(el('img', {src: m.coverUrl, alt: ''}));
    else cover.append(icon('audio'));
    box.append(cover);

    const meta = el('div', {class: 'media__meta'});
    meta.append(el('div', {
        class: 'media__title',
        textContent: m.title || m.fileName || 'Audio',
    }));
    meta.append(el('div', {
        class: 'media__sub',
        textContent: [m.performer, duration(m.duration)].filter(Boolean).join(' · '),
    }));
    if (m.url) meta.append(el('audio', {controls: true, src: m.url, preload: 'none'}));
    else {
        meta.append(el('button', {
            class: 'media__action', type: 'button',
            onclick: () => ensure(msg, 'full'),
        }, 'Load track'));
    }
    box.append(meta);
    return box;
}

function renderVoice(msg, m) {
    const box = el('div', {class: 'media media--audio'});
    box.append(el('div', {class: 'media__cover'}, icon('mic')));
    const meta = el('div', {class: 'media__meta'});
    meta.append(el('div', {class: 'media__title', textContent: 'Voice message'}));
    meta.append(el('div', {class: 'media__sub', textContent: duration(m.duration)}));
    if (m.url) meta.append(el('audio', {controls: true, src: m.url, preload: 'none'}));
    else {
        meta.append(el('button', {
            class: 'media__action', type: 'button',
            onclick: () => ensure(msg, 'full'),
        }, 'Load voice'));
    }
    box.append(meta);
    return box;
}

function renderFile(msg, m) {
    const box = el('div', {class: 'media media--file'});
    box.append(el('div', {class: 'media__cover'}, icon('file')));
    const meta = el('div', {class: 'media__meta'});
    meta.append(el('div', {class: 'media__title', textContent: m.fileName || 'File'}));
    meta.append(el('div', {class: 'media__sub', textContent: fileSize(m.size)}));
    box.append(meta);

    if (m.url) {
        box.append(el('a', {
            class: 'media__action', href: m.url, download: m.fileName || '',
        }, 'Save'));
    } else {
        box.append(el('button', {
            class: 'media__action', type: 'button',
            onclick: () => ensure(msg, 'full'),
        }, 'Download'));
    }
    return box;
}

function renderSticker(msg, m) {
    const box = el('div', {class: 'media media--sticker'});
    if (!m.url) {
        box.append(el('div', {class: 'media__sticker-wait', textContent: '…'}));
        return box;
    }
    if (m.format === 'webm') {
        box.append(el('video', {
            class: 'media__sticker',
            src: m.url, autoplay: true, loop: true, muted: true, playsInline: true,
        }));
    } else if (m.format === 'tgs') {
        // A gzip-compressed Lottie animation. The native window renders
        // these through rlottie; the browser would need a Lottie player,
        // which is not in this project. Shown as a labelled placeholder
        // rather than silently blank.
        box.append(el('div', {class: 'media__sticker-wait', textContent: 'animated sticker'}));
    } else {
        box.append(el('img', {class: 'media__sticker', src: m.url, alt: ''}));
    }
    return box;
}

// ------------------------------------------------------------ poll
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
function renderReactions(msg) {
    const strip = el('footer', {class: 'message__reactions'});
    for (const r of msg.reactions) {
        const pill = el('span', {
            class: `reaction${r.chosen ? ' is-chosen' : ''}`,
        });
        if (r.kind === 'emoji') {
            pill.append(el('span', {class: 'reaction__emoji', textContent: r.emoji}));
        } else if (r.kind === 'paid') {
            pill.append(el('span', {class: 'reaction__emoji', textContent: '★'}));
        } else {
            // A Premium custom emoji. The sticker behind it is not exposed to
            // the page yet, so the counter stands on its own rather than
            // showing a wrong glyph.
            pill.append(el('span', {class: 'reaction__emoji', textContent: '•'}));
        }
        pill.append(String(r.count));
        strip.append(pill);
    }
    return strip;
}
