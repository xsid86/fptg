import PhotoSwipeLightbox from '../../vendor/photoswipe/photoswipe-lightbox.esm.js';
import {el} from '../core/dom.js';
import {on} from '../core/bus.js';
import {icon} from '../util/icons.js';

// The full-size viewer, and the gallery an album opens into.
//
// Before this, clicking a photo called window.open() - which inside the
// WebView2 shell is a NewWindowRequested and therefore handed straight
// to the system browser. The picture genuinely left the application.
//
// PhotoSwipe (MIT, vendored under assets/vendor) does the zooming,
// swiping and the slide track. NOTE THE TRADE THIS MAKES: it positions
// everything with inline transforms, so the app's rule that JavaScript
// only ever changes classes does not hold inside the viewer. That was a
// deliberate choice, not an oversight - the rule still governs every
// line we write ourselves, including the two things added here.
//
// Those two are VIDEO SLIDES and the THUMBNAIL STRIP. Neither is a
// plugin: PhotoSwipe leaves both to the host, and both come out at a
// few dozen lines built with the same el() helper as the rest of the
// app - no vendored HTML strings, no second licence to carry.
//
// The core is loaded on demand: nobody who never opens a picture pays
// for it. The dynamic import is authorised by the session cookie the
// server set when the page loaded, so it needs no token of its own.

// Room left at the bottom for the strip, so a picture is never hidden
// behind it. Keep in sync with .pswp__thumbs in blocks/_viewer.scss.
const THUMBS_HEIGHT = 92;

let current = null;
// The slide data PhotoSwipe is reading (it holds this very array, so a
// slot replaced here is what the next refresh picks up) and, in step
// with it, the message each slide came from.
let items = [];
let shown = [];

/**
 * A message as one slide, or null when it cannot be one.
 *
 * A video only becomes a slide once its file is here: the viewer plays
 * the real thing, and there is nothing to play before the download
 * finishes. Clicking such a cell starts that download instead, so the
 * slide appears on the next open.
 */
function slide(msg) {
    const m = msg.media;
    if (!m) return null;

    if (msg.kind === 'photo') {
        // The original if it is already downloaded, the inline preview
        // if not: opening instantly on the preview beats a blank frame
        // while the full file arrives, and refreshFrom() swaps the
        // sharp one in as soon as it lands.
        const src = m.fullUrl || m.url;
        if (!src) return null;
        // THE ORIGINAL'S SIZE EITHER WAY. PhotoSwipe fits a slide to at
        // most 1:1 - it never enlarges - so describing the preview by
        // its own dimensions opens it at preview size, which is the
        // "first open is small, the second is big" bug: the second open
        // was simply the first one that had the original to measure.
        // Claiming the full size scales the preview up instead, which
        // is soft for a moment and the right size from the start.
        const width = m.fullW || m.w || 0;
        const height = m.fullH || m.h || 0;
        return {
            type: 'image',
            src,
            // What PhotoSwipe shows during the opening animation, and
            // what the strip shows.
            msrc: m.url || m.thumb || src,
            thumb: m.url || m.thumb || src,
            // A zero would collapse the slide, so a frame rather than a
            // guess when nothing reported a size at all.
            width: width || 1600,
            height: height || 1200,
        };
    }

    if (msg.kind === 'video' || msg.kind === 'animation') {
        if (!m.url) return null;
        return {
            type: 'video',
            src: m.url,
            poster: m.thumbUrl || m.thumb || '',
            thumb: m.thumbUrl || m.thumb || '',
            loop: msg.kind === 'animation',
            // Not for zooming - a video is not zoomable - but for the
            // box PhotoSwipe fits it into, which is what makes it
            // letterbox correctly instead of filling the window.
            width: m.w || 1280,
            height: m.h || 720,
        };
    }

    return null;
}

/** Открыт ли просмотрщик — окну настроек, чтобы Esc не закрыл и его. */
export function viewerOpen() {
    return current !== null;
}

export function closeViewer() {
    if (current) {
        current.destroy();
        current = null;
    }
    items = [];
    shown = [];
}

/**
 * The picture a slide is showing has changed underneath it - almost
 * always the original arriving for a slide opened on the preview.
 *
 * Only ever swaps a slide in place. The number of slides stays what it
 * was when the viewer opened, so a video that finishes downloading
 * while the gallery is open joins it on the next open rather than
 * appearing under the counter mid-swipe.
 */
function refreshFrom(state) {
    const pswp = current?.pswp;
    if (!pswp || !state?.items?.length) return;

    const byId = new Map(state.items.map((msg) => [msg.id, msg]));
    shown.forEach((id, i) => {
        const msg = byId.get(id);
        if (!msg) return;
        const next = slide(msg);
        if (!next || next.src === items[i].src) return;
        items[i] = next;
        pswp.refreshSlideContent(i);
    });
}

// Subscribed once, for the lifetime of the module: the guard above is
// what makes it free while nothing is open.
on('store:messages', refreshFrom);

/** A <video> for one slide, played by the viewer rather than in place. */
function videoElement(data) {
    const video = el('video', {
        class: 'pswp__video',
        src: data.src,
        poster: data.poster || null,
        controls: true,
        playsInline: true,
        loop: Boolean(data.loop),
        preload: 'metadata',
    });
    // PhotoSwipe reads a drag anywhere on the surface as a swipe, which
    // would make the scrubber unusable: dragging along the timeline
    // would page to the next slide instead of seeking. Pointers that
    // start on the video belong to the video; swiping stays available
    // everywhere around it, and the arrows, the strip and the arrow
    // keys do not care either way.
    video.addEventListener('pointerdown', (e) => e.stopPropagation());
    return video;
}

/** The strip along the bottom: every slide at a glance, click to go. */
function mountThumbs(node, pswp, items) {
    const buttons = items.map((item, i) => {
        const button = el('button', {
            class: 'pswp__thumb',
            type: 'button',
            ariaLabel: `Item ${i + 1} of ${items.length}`,
            onclick: () => pswp.goTo(i),
        });
        if (item.thumb) {
            button.append(el('img', {class: 'pswp__thumb-img', src: item.thumb, alt: ''}));
        }
        if (item.type === 'video') {
            button.append(el('span', {class: 'pswp__thumb-play'}, icon('play')));
        }
        return button;
    });
    node.append(...buttons);

    const sync = () => {
        buttons.forEach((b, i) => b.classList.toggle('is-active', i === pswp.currIndex));
        buttons[pswp.currIndex]?.scrollIntoView({block: 'nearest', inline: 'center'});
    };
    pswp.on('change', sync);
}

/**
 * Opens the viewer on `msgs`, starting at `startIndex`. Returns false
 * when there was nothing showable, so the caller can decide what to do
 * instead of assuming a window appeared.
 */
/**
 * `options.container` — куда вешать просмотрщик (по умолчанию body).
 * Из модального <dialog> он должен жить внутри диалога: диалог лежит в
 * верхнем слое, и всё, что в body, оказалось бы под ним.
 * `options.actions` — кнопки на верхней полосе: { name, title,
 * onClick(index) }, index — номер слайда в переданном списке.
 */
export function openViewer(msgs, startIndex, options = {}) {
    const built = [];
    const ids = [];
    let index = 0;

    msgs.forEach((msg, i) => {
        const s = slide(msg);
        if (!s) return;
        // The starting slide is counted in the FILTERED list: a message
        // that cannot be shown would otherwise shift every index after
        // it.
        if (i <= startIndex) index = built.length;
        built.push(s);
        ids.push(msg.id);
    });
    if (!built.length) return false;

    closeViewer();
    items = built;
    shown = ids;

    const strip = items.length > 1;
    const lightbox = new PhotoSwipeLightbox({
        dataSource: items,
        bgOpacity: 0.95,
        // A desktop shell, so clicking beside the picture closes - the
        // same gesture the native viewer answers to.
        clickToCloseNonZoomable: true,
        padding: {top: 0, bottom: strip ? THUMBS_HEIGHT : 0, left: 0, right: 0},
        pswpModule: () => import('../../vendor/photoswipe/photoswipe.esm.js'),
        appendToEl: options.container ?? undefined,
    });

    // A slide PhotoSwipe does not know how to build itself. Answering
    // contentLoad is the whole of it: hand back an element, say it is
    // loaded, and the rest of the machinery - the fitting, the counter,
    // the swipe - treats it like any other slide.
    lightbox.on('contentLoad', (e) => {
        const {content} = e;
        if (content.type !== 'video') return;
        e.preventDefault();
        content.element = el('div', {class: 'pswp__content pswp__video-box'},
            videoElement(content.data));
        content.state = 'loaded';
        content.onLoaded();
    });

    // Play what is on screen, and stop what is not: without this a
    // video keeps playing out of sight after a swipe.
    lightbox.on('contentActivate', ({content}) => {
        const video = content.element?.querySelector('video');
        if (video) video.play().catch(() => {});
    });
    lightbox.on('contentDeactivate', ({content}) => {
        const video = content.element?.querySelector('video');
        if (video) video.pause();
    });

    const actions = options.actions ?? [];
    if (strip || actions.length) {
        lightbox.on('uiRegister', () => {
            const pswp = lightbox.pswp;
            if (strip) {
                pswp.ui.registerElement({
                    name: 'thumbs',
                    order: 9,
                    appendTo: 'root',
                    onInit: (node) => mountThumbs(node, pswp, items),
                });
            }
            // Текстовые кнопки перед крестиком (у него order 20).
            actions.forEach((action, i) => {
                pswp.ui.registerElement({
                    name: action.name,
                    order: 15 + i,
                    isButton: true,
                    title: action.title,
                    onInit: (node) => {
                        node.classList.add('pswp__action');
                        node.textContent = action.title;
                    },
                    onClick: () => action.onClick(pswp.currIndex),
                });
            });
        });
    }

    // Built fresh per open and dropped on close rather than kept
    // around: the data source is a different set of pictures every
    // time, and a reused instance would have to be re-armed anyway.
    lightbox.on('destroy', () => {
        if (current === lightbox) current = null;
    });

    lightbox.init();
    lightbox.loadAndOpen(index);
    current = lightbox;
    return true;
}
