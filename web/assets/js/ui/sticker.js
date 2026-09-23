import { on } from '../core/bus.js';

// Animated stickers.
//
// A .tgs is a Lottie animation, gzip-compressed - the same file the
// native window hands to rlottie (see lottieplayer.pas). Unpacking it
// costs nothing here: DecompressionStream is part of the engine, so no
// inflate library is vendored for it.
//
// The native player renders at three times the display size and box-
// downscales, because a rasterizer aimed straight at a 170px grid
// drops fine detail (RENDER_SCALE in lottieplayer.pas). There is no
// analogue here and none is needed: the renderer below is vector, so
// the browser rasterizes at whatever the screen actually is.
//
// THE ENGINE IS lottie-web (MIT, vendored under assets/vendor), AND
// THAT IS THE ONE THING TO KEEP AN EYE ON. The native window does not
// use stock rlottie: vanilla Samsung rlottie was proved, with its own
// official lottie2gif tool, to silently skip detail in real Telegram
// stickers, which is why this project ports the Telegram X fork (see
// the entry of 2026-09-05 in docs/journal/). lottie-web is a different
// implementation again - bodymovin's own, the reference one for the
// format - so it is not the library that failed there, but it is also
// not the one the native window draws with. If a sticker comes out
// wrong, the replacement is rlottie-wasm built from that same fork,
// and this module is the whole surface that would change: everything
// else only calls playSticker.
//
// Playback follows what is on screen. An animation off-screen is
// paused rather than stopped, and one whose node the history has
// replaced is destroyed - a sticker left running in a detached node
// keeps its rAF loop forever, and the history rebuilds nodes whenever
// a message's payload changes.

// Parsed animations, kept by URL: the same sticker appears over and
// over in a chat, and parsing the JSON is the expensive half.
const CACHE_LIMIT = 24;
const parsed = new Map();

// container node -> the lottie animation drawing into it
const live = new Map();

let engine = null;
let loading = null;
let watcher = null;

function observer() {
    if (!watcher) {
        watcher = new IntersectionObserver((entries) => {
            for (const entry of entries) {
                const anim = live.get(entry.target);
                if (!anim) continue;
                if (entry.isIntersecting) anim.play();
                else anim.pause();
            }
        }, { rootMargin: '150px' });
    }
    return watcher;
}

function loadEngine() {
    if (engine) return Promise.resolve(engine);
    if (!loading) {
        // On demand, like the picture viewer: nobody who never sees an
        // animated sticker pays for half a megabyte of player.
        loading = import('../../vendor/lottie/lottie.esm.js').then((m) => {
            engine = m.default;
            return engine;
        });
    }
    return loading;
}

async function animationData(url) {
    const known = parsed.get(url);
    if (known) return known;

    const res = await fetch(url);
    if (!res.ok) throw new Error(`sticker ${res.status}`);
    const text = await new Response(
        res.body.pipeThrough(new DecompressionStream('gzip'))).text();
    const data = JSON.parse(text);

    parsed.set(url, data);
    if (parsed.size > CACHE_LIMIT) parsed.delete(parsed.keys().next().value);
    return data;
}

function drop(node) {
    const anim = live.get(node);
    if (!anim) return;
    live.delete(node);
    observer().unobserve(node);
    anim.destroy();
}

/**
 * Animations whose node is no longer in the document.
 *
 * Hung on the same event that makes the history rebuild its nodes, so
 * the sweep happens exactly when nodes are replaced and costs nothing
 * the rest of the time.
 */
function sweep() {
    for (const node of [...live.keys()]) {
        if (!node.isConnected) drop(node);
    }
}
on('store:messages', sweep);

/**
 * Draws the .tgs at `url` inside `node`, looping. Resolves to false if
 * it could not be played, so the caller can say so instead of leaving
 * an empty frame.
 */
export async function playSticker(node, url) {
    try {
        const [lottie, data] = await Promise.all([loadEngine(), animationData(url)]);
        // The node may have been thrown away while we were fetching.
        if (!node.isConnected) return false;
        drop(node);

        const anim = lottie.loadAnimation({
            container: node,
            // SVG, NOT canvas, and this was measured rather than
            // chosen: lottie-web's canvas renderer draws this
            // library's GRADIENT FILLS wrong. On the screaming-face
            // sticker - 7 "gf" items, plain 3-stop linear ones plus
            // two radial - the face came out almost white instead of
            // the yellow-to-blue it has in the official client, at
            // every dpr. The same file through the SVG renderer is
            // right. Its edges are also softer, because the browser
            // antialiases vectors itself, which is the other half of
            // what the native window looked like next to us.
            //
            // The cost is a DOM per sticker instead of one canvas.
            // Acceptable here: few stickers are on screen at once and
            // off-screen ones are paused. If a wall of them ever bites,
            // the answer is the rlottie-wasm swap above, not canvas.
            //
            // Nothing from the file reaches the document as MARKUP
            // either way: lottie builds these nodes with
            // createElementNS from parsed JSON, the same way this app
            // builds its own (see core/dom.js).
            renderer: 'svg',
            loop: true,
            autoplay: true,
            animationData: data,
        });
        live.set(node, anim);
        observer().observe(node);
        return true;
    } catch (err) {
        console.error('sticker', url, err);
        return false;
    }
}
