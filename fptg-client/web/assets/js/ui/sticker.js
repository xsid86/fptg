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
// The nodes whose animation runs ONCE per appearance - stickers, as
// against the badges (which never run) and anything that loops.
const once = new Set();

let engine = null;
let loading = null;
let watcher = null;

function observer() {
    if (!watcher) {
        watcher = new IntersectionObserver((entries) => {
            for (const entry of entries) {
                const anim = live.get(entry.target);
                if (!anim) continue;
                if (!entry.isIntersecting) {
                    // Leaving parks it on its first frame, which is
                    // also what makes the NEXT arrival a fresh
                    // showing rather than a resumption.
                    if (once.has(entry.target)) anim.goToAndStop(0, true);
                    else anim.pause();
                    continue;
                }
                if (once.has(entry.target)) anim.goToAndPlay(0, true);
                else anim.play();
            }
            // NO MARGIN. An animation that is not on screen is not
            // being watched, and the compositor wakes the window for
            // every frame of it regardless. The margin used to be
            // 150px, which bought a sticker being already in motion by
            // the time it arrived - not worth paying for continuously.
        }, { rootMargin: '0px' });
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
    once.delete(node);
    observer().unobserve(node);
    anim.destroy();
}

/**
 * Animations whose node is no longer in the document.
 *
 * THIS USED TO HANG ON store:messages ALONE, and that was a leak with
 * a sixteen-hour fuse. The CHAT LIST also holds animated custom emoji,
 * and store:chats fires for a message in ANY chat while store:messages
 * fires only for the open one. A busy account with a quiet chat open
 * therefore refreshed the list thousands of times with nothing ever
 * sweeping, and the registry is a strong map: every row it threw away
 * left its player, its parsed data and its SVG tree behind. Measured:
 * 150 list rebuilds took the JS heap from 5 MB to 114 MB; the same 150
 * with a sweep after each left it at 5 MB.
 *
 * The list now reuses the rows it can (see ui/chat-list.js), so it
 * throws far fewer away - but "far fewer" is not "none", and a row
 * whose chat changed is still rebuilt.
 *
 * So it now hangs on both events AND runs before every new animation.
 * The last one is what makes it self-healing: whatever event does or
 * does not fire, the registry cannot outgrow the nodes actually in the
 * document by more than one render.
 */
function sweep() {
    for (const node of [...live.keys()]) {
        if (!node.isConnected) drop(node);
    }
}
on('store:messages', sweep);
on('store:chats', sweep);

/**
 * Рисует ОДИН кадр .tgs на `canvas` и сразу уничтожает плеер: от
 * анимации остаются только пиксели холста.
 *
 * Для сеток, где ячеек сотня, а смотрят на одну: панель эмодзи держала
 * по живому SVG-плееру на ячейку, и один анимированный набор кастомных
 * эмодзи стоил процессу WebView2 около 2 ГБ (статичный — копейки,
 * измерено пользователем в диспетчере задач). Холст размером с ячейку
 * — это килобайты.
 *
 * Canvas-рендерер, а не SVG: у него изъян с градиентами (см. выше), но
 * на размере буквы он не виден — по той же причине им рисуются значки.
 * Плеер рисует в ПЕРЕДАННЫЙ контекст без контейнера: размер тогда
 * берётся из самого холста (CanvasRendererBase.updateContainerSize), а
 * destroy() без контейнера пиксели не стирает. dpr при переданном
 * контексте по умолчанию 1 — поэтому он передаётся явно, иначе на
 * HiDPI кадр мылится.
 */
export async function stillSticker(canvas, url, size) {
    try {
        const [lottie, data] = await Promise.all([loadEngine(), animationData(url)]);
        // Холст может быть и не в документе — черновик, который потом
        // перегоняется в картинку (см. makeStill в picker.js).
        canvas.width = size;
        canvas.height = size;
        const anim = lottie.loadAnimation({
            renderer: 'canvas',
            loop: false,
            autoplay: false,
            animationData: data,
            rendererSettings: {
                context: canvas.getContext('2d'),
                clearCanvas: true,
                dpr: window.devicePixelRatio || 1,
            },
        });
        if (!anim.isLoaded) {
            await new Promise((resolve) => anim.addEventListener('DOMLoaded', resolve));
        }
        anim.goToAndStop(0, true);
        anim.destroy();
        return true;
    } catch (err) {
        console.error('sticker still', url, err);
        return false;
    }
}

/**
 * Один кадр .tgs как КАРТИНКА: адрес data:image/svg+xml для <img>, или
 * null. Плеер уничтожается сразу — от стикера остаётся одна картинка.
 *
 * Для стикеров, а не эмодзи: на размере плитки изъян canvas-рендерера
 * с градиентами виден (см. playSticker), поэтому кадр строит
 * SVG-рендерер — в ОТЦЕПЛЕННЫЙ контейнер, — и его <svg> сериализуется.
 * Градиенты, маски и клипы ссылаются на id внутри того же <svg>,
 * поэтому самостоятельный документ рисуется так же, как живой плеер.
 * viewBoxOnly: в корень не пишутся ни размеры, ни инлайн-стили, и
 * картинка вписывается в плитку по viewBox.
 */
export async function stillSvg(url) {
    try {
        const [lottie, data] = await Promise.all([loadEngine(), animationData(url)]);
        const box = document.createElement('div');
        const anim = lottie.loadAnimation({
            container: box,
            renderer: 'svg',
            loop: false,
            autoplay: false,
            animationData: data,
            rendererSettings: { viewBoxOnly: true },
        });
        if (!anim.isLoaded) {
            await new Promise((resolve) => anim.addEventListener('DOMLoaded', resolve));
        }
        anim.goToAndStop(0, true);
        const svg = box.querySelector('svg');
        const markup = svg ? new XMLSerializer().serializeToString(svg) : '';
        anim.destroy();
        return markup ? `data:image/svg+xml;charset=utf-8,${encodeURIComponent(markup)}` : null;
    } catch (err) {
        console.error('sticker svg still', url, err);
        return null;
    }
}

/**
 * Уничтожает плееры внутри `root` сразу, не дожидаясь sweep().
 *
 * sweep() срабатывает по событиям истории и списка или перед следующим
 * плеером — а панель эмодзи выбрасывает целый набор разом, и сотня
 * отцепленных плееров с SVG-деревьями жила до случайного повода.
 */
export function stopStickers(root) {
    if (!root) return;
    for (const node of [...live.keys()]) {
        if (node === root || root.contains(node)) drop(node);
    }
}

/**
 * Draws the .tgs at `url` inside `node`, looping. Resolves to false if
 * it could not be played, so the caller can say so instead of leaving
 * an empty frame.
 */
/**
 * Сменить, как играют уже показанные стикеры внутри root (Battery and
 * animation, Chat settings): loop — по кругу, иначе раз за показ; still —
 * стоят первым кадром до щелчка. Значки (badge) не трогает.
 */
export function restyleStickers(root, { loop, still }) {
    for (const [node, anim] of live) {
        if (!node.classList.contains('media__sticker--lottie') || !root.contains(node)) continue;
        anim.loop = !!loop && !still;
        if (loop) once.delete(node);
        else once.add(node);
        if (still) {
            observer().unobserve(node);
            anim.goToAndStop(0, true);
        } else {
            // Заново под наблюдение: первый же отклик (на экране) и
            // запустит его по новым правилам.
            observer().unobserve(node);
            observer().observe(node);
        }
    }
}

export async function playSticker(node, url, opts = {}) {
    const badge = !!opts.badge;
    try {
        const [lottie, data] = await Promise.all([loadEngine(), animationData(url)]);
        // The node may have been thrown away while we were fetching.
        if (!node.isConnected) return false;
        // Everything the last render left behind - see sweep().
        sweep();
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
            // Acceptable here: few stickers are on screen at once,
            // off-screen ones are stopped, and each visible one runs a
            // single pass. rlottie is NOT the answer if a wall of them
            // ever bites - it was weighed and turned down: not smooth
            // under LCL, and in the browser it loses colours and
            // layers. Drawing quality is the point of this renderer.
            //
            // Nothing from the file reaches the document as MARKUP
            // either way: lottie builds these nodes with
            // createElementNS from parsed JSON, the same way this app
            // builds its own (see core/dom.js).
            // A BADGE IS A STILL PICTURE. An emoji status or a custom
            // emoji in a line of text is drawn at the size of a letter,
            // and animating one is not free at any size: the
            // compositor has to wake the window for every frame.
            // Measured on the app's own renderer, sitting idle with no
            // chat open, three 16x16 statuses in the chat list cost
            // 0.17 of a core plus 0.08 in the GPU process - and hiding
            // them took both to ZERO.
            //
            // Canvas as well as still, because lottie's SVG renderer
            // builds its picture by rewriting a DOM tree, and that is
            // most of what the frame above cost. The gradient flaw
            // that rules canvas out for a real sticker is invisible at
            // the size of a letter.
            renderer: badge ? 'canvas' : 'svg',
            // A sticker is shown, not looped: it plays once when it
            // comes into view and then stands still. Only the things
            // that are meant to run forever keep looping.
            loop: !badge && !opts.once,
            autoplay: false,
            animationData: data,
        });
        live.set(node, anim);
        if (opts.once) {
            once.add(node);
            // Back to the first frame when the run is over, so what
            // stays on screen is the sticker's own face rather than
            // whatever pose it ended in.
            anim.addEventListener('complete', () => anim.goToAndStop(0, true));
        }
        if (!badge) {
            // Clicking replays it from the start, the way the original
            // client does. It is also the way back for anything the
            // rule above has stopped.
            node.addEventListener('click', () => anim.goToAndPlay(0, true));
            // A face to wear until the observer speaks. Nothing
            // autoplays any more, and the observer's first word about
            // a newly watched node arrives a task later - without this
            // there is a blank sticker-sized hole until then.
            anim.goToAndStop(0, true);
        }
        if (badge) {
            // One frame, then nothing. NOT watched either: the watcher
            // exists to play what comes into view, which is the one
            // thing this must not do.
            anim.goToAndStop(0, true);
        } else if (opts.still) {
            // «Animated stickers» выключены (util/prefs.js): лицо стоит,
            // играет только по щелчку — наблюдатель не нужен.
        } else {
            observer().observe(node);
        }
        return true;
    } catch (err) {
        console.error('sticker', url, err);
        return false;
    }
}
