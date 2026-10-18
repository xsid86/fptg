import { el, clear, qs, qsa } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { playSticker, stillSticker, stillSvg, stopStickers } from './sticker.js';
import { sideScroll } from '../util/sidescroll.js';
import { markPopDirection } from '../util/pop.js';
import { holdVideo, forget } from '../util/offscreen.js';

// The emoji / sticker / GIF panel, the one thing in the composer that
// is an icon rather than a word - a smiley, because that is what a
// smiley means and no label would say it shorter.
//
// A popover, for the same two reasons util/menu.js is one: the top
// layer means nothing clips it, and light dismiss plus Escape come with
// it rather than being written here. Position is a class on the anchor,
// never an inline style.
//
// WHICH EMOJI ARE OFFERED is decided offline, by the generator that
// wrote assets/data/emoji.json from Unicode's emoji-test.txt
// (build_emoji.py, removed 2026-10-12 - it is in git history).
//
// Stickers and GIFs are the other half: those are not text at all. A
// click SENDS one, the way it does in every Telegram client - there is
// nothing to insert into a text box.

const DATA_URL = 'assets/data/emoji.json';
const RECENT_KEY = 'tg.picker.recent';
const TONE_KEY = 'tg.picker.tone';
const RECENT_MAX = 32;

// The five Fitzpatrick modifiers, in the order emoji.json lists them.
const TONE_SWATCH = ['✋', '✋\u{1F3FB}', '✋\u{1F3FC}',
  '✋\u{1F3FD}', '✋\u{1F3FE}', '✋\u{1F3FF}'];

let anchor = null;
let mounted = null;   // the composer's smiley - where the panel normally hangs
let hooks = {};
// Set while the panel is being used to answer a question - "which
// emoji?" - rather than to type into the composer. One shot: it is
// cleared by the pick it answers.
let oneShot = null;
let panel = null;
let tab = 'emoji';
let catalogue = null;      // emoji.json, fetched once
let tone = 0;
let query = '';
let queryTimer = 0;

// Each tab searches something different, and says so.
const PLACEHOLDER = {
  emoji: 'Search emoji',
  stickers: 'Search stickers',
  gif: 'Search GIFs',
};
// Every cell that has skin-tone variants, paired with its item. Built
// once with the grid: changing the tone then means writing 306 text
// nodes, not searching the panel 306 times over.
let toneCells = [];
// One container per tab, kept between openings. The emoji grid is 1895
// buttons and takes ~200 ms to build; rebuilding it every time the
// panel opens was measured and is exactly the lag that makes a picker
// feel heavy. Stickers and GIFs ARE rebuilt on every opening, because
// what the account has can change between two of them.
const panes = {};

// ---------------------------------------------------------- storage
// Two preferences that belong to this browser and nowhere else: what
// was picked recently and which skin tone to prefer. localStorage
// rather than the server, because the native window has no picker to
// share them with.
function readStore(key, fallback) {
  try {
    const raw = window.localStorage.getItem(key);
    return raw === null ? fallback : JSON.parse(raw);
  } catch {
    return fallback;
  }
}

function writeStore(key, value) {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch { /* private mode, or a full quota - not worth a word */ }
}

function remember(char) {
  const list = readStore(RECENT_KEY, []).filter((c) => c !== char);
  list.unshift(char);
  writeStore(RECENT_KEY, list.slice(0, RECENT_MAX));
}

/**
 * Releases everything heavy inside `root`: Lottie players, videos (the
 * decoder and buffers — only by removing src and load()) and offscreen
 * observation.
 *
 * CALL BEFORE clear(): after it the nodes are no longer inside root, and
 * there is nothing to find them by. That is exactly how the panel leaked —
 * clear() detached the nodes, while players and videos lived on: a few
 * switches between custom emoji sets gave 2.6 GB in the WebView2 process.
 */
function releaseMedia(root) {
  if (!root) return;
  stopStickers(root);
  forget(root);
  for (const still of root.querySelectorAll('.picker__still')) {
    stillJobs.delete(still);
    lazy?.unobserve(still);
  }
  for (const video of root.querySelectorAll('video')) {
    video.pause();
    video.removeAttribute('src');
    video.load();
  }
}

/** The variant of an emoji for the tone currently chosen. */
const toned = (item) => (tone > 0 && item.t ? item.t[tone - 1] : item.e);

// ------------------------------------------------------------ emoji
/**
 * A Premium custom emoji, answered as an object rather than a
 * character - it has no character to be.
 *
 * For a reaction — the answer to "which emoji?". In the composer — insertion
 * as an entity (composer.insertCustomEmoji): the field (ui/editor.js) draws
 * it as a picture and sends textEntityTypeCustomEmoji.
 * The panel stays open meanwhile, as for ordinary emoji.
 */
function pickCustom(item) {
  if (oneShot) {
    const answer = oneShot;
    oneShot = null;
    hide();
    answer({ customEmojiId: item.id, emoji: item.emoji });
    return;
  }
  // With the file address: the input field draws the emoji as a picture at once.
  hooks.insertCustom?.(item.id, item.emoji, item);
}

const customCell = (item) => el('button', {
  class: 'picker__cell picker__cell--custom',
  type: 'button',
  title: item.emoji || 'Custom emoji',
  dataset: { id: item.id },
  onclick: () => pickCustom(item),
  onpointerenter: (event) => goLive(event.currentTarget, item),
  onpointerleave: (event) => stopLive(event.currentTarget),
}, stickerNode(item, { still: true }));

/**
 * A live player — only for the cell under the cursor, over its frame, and
 * it is destroyed as soon as the cursor leaves. So at any moment no more
 * than one emoji plays in the grid.
 */
function goLive(cell, item) {
  if (item.format !== 'tgs' && item.format !== 'webm' && item.format !== 'mp4') return;
  if (!item.url || cell.classList.contains('is-live')) return;
  // A GIF is an mp4 without sound: under the cursor just a playing video.
  const live = item.format === 'mp4'
    ? el('video', {
      class: 'picker__gif', src: item.url,
      autoplay: true, loop: true, muted: true, playsInline: true,
    })
    : stickerNode(item);
  live.classList.add('picker__live');
  cell.append(live);
  cell.classList.add('is-live');
}

function stopLive(cell) {
  const live = qs('.picker__live', cell);
  if (!live) return;
  releaseMedia(live);
  live.remove();
  cell.classList.remove('is-live');
}

/**
 * ONE SET AT A TIME, not all of them down one list.
 *
 * Measured the hard way: an account's installed custom emoji run into
 * the hundreds, most of them animated, and each animated one is a
 * Lottie player of its own. Laying every set out in a single scroller
 * meant building and running the lot at once, which is exactly the
 * "brutal lag" it was reported as - and it also pushed the ordinary
 * emoji off the top of the panel.
 *
 * So the strip at the bottom SWITCHES rather than scrolls: the
 * standard emoji are one view (the default, all nine groups in one
 * scroller as before), and each custom set is another. Nothing outside
 * the view being shown exists in the document at all.
 */
let sets = [];          // what emoji.sets last answered
let shownSet = null;    // id of the custom set on screen, null = the standard ones

/** Asks for one set's emoji the first time it is looked at. */
function wantSet(id) {
  const set = sets.find((x) => x.id === id);
  if (!set || set.loaded) return;
  hooks.load?.('emoji.set', { id }).catch(() => { /* the panel stays as it is */ });
}

/**
 * Draws a set by APPENDING what has arrived, not rebuilding everything.
 *
 * While a set's files download, the stickers event comes up to five times a
 * second, and each used to recreate all the cells — a hundred players and
 * videos at once, while the old ones stayed alive. Now a ready cell stays
 * as it is, a new one takes its place in the set's order, and the set is
 * torn down whole (with releasing) only when the set changes.
 */
function renderCustomSet(box, set) {
  if (!set || box.dataset.set !== set.id) {
    releaseMedia(box);
    clear(box);
    delete box.dataset.set;
  }
  if (!set) return;
  box.dataset.set = set.id;

  let section = qs('.picker__section', box);
  if (!section) {
    section = el('section', { class: 'picker__section' },
      el('h3', { class: 'picker__heading' }, set.title),
      el('div', { class: 'picker__grid' }));
    box.append(section);
  }
  const grid = qs('.picker__grid', section);
  const have = new Map(qsa('.picker__cell--custom', grid).map((c) => [c.dataset.id, c]));
  const ready = set.emoji.filter((e) => e.url);
  let prev = null;
  for (const item of ready) {
    let cell = have.get(item.id);
    if (!cell) {
      cell = customCell(item);
      if (prev) prev.after(cell);
      else grid.prepend(cell);
    }
    prev = cell;
  }

  const empty = qs('.picker__empty', section);
  if (ready.length) empty?.remove();
  else if (!empty) section.append(el('p', { class: 'picker__empty' }, 'Loading…'));
}

/**
 * Switches the body between the standard emoji and one custom set.
 * `id` of null means the standard ones, which is where the panel
 * starts and where searching always goes.
 */
function showSet(id) {
  shownSet = id;
  const sections = qs('.picker__sections', panel);
  const box = qs('.picker__custom', panel);
  if (!sections || !box) return;

  sections.hidden = id !== null;
  box.hidden = id === null;
  // Only the switching buttons carry the mark. The nine group buttons
  // all lead to the same (default) view and would otherwise all light
  // up at once.
  for (const button of qsa('.picker__jump--custom', panel)) {
    button.classList.toggle('is-active', button.dataset.set === id);
  }
  const standard = qs('.picker__jump--standard', panel);
  standard?.classList.toggle('is-active', id === null);
  centreJump(id === null ? standard : qs('.picker__jump.is-active', panel));
  if (id === null) {
    renderCustomSet(box, null);
    return;
  }
  renderCustomSet(box, sets.find((x) => x.id === id));
  wantSet(id);
  qs('.picker__body', panel).scrollTop = 0;
}

/**
 * What a set's button in the strip wears.
 *
 * The set's COVER first - stickerSetInfo carries a few of the set's own
 * stickers for exactly this, so the button can show the set before
 * anything inside it has been asked for. Then, if that has not
 * arrived, the first emoji that has. The character is the last resort:
 * a strip of letters is what this looked like before the cover was
 * fetched, and it looked like nothing at all.
 */
function setArt(set) {
  return set.cover?.url ? set.cover : set.emoji.find((e) => e.url);
}

/**
 * A set's icon is STILL: a frame, not a loop. Three dozen sets in the strip,
 * each with its own player or video, spun all the time the panel was open —
 * for the sake of icons nobody looks at.
 */
function setIcon(set) {
  const art = setArt(set);
  if (art) return stickerNode(art, { still: true });
  return set.cover?.emoji || set.emoji[0]?.emoji || set.title.slice(0, 1);
}

/** What is drawn on the set's button now — so as not to redraw the same. */
const setIconKey = (set) => setArt(set)?.url ?? `text:${set.title}`;

/**
 * The head of the strip: a way back to the standard emoji, then one
 * button per custom set.
 *
 * The way back is its own button rather than "click any of the nine
 * group buttons", which worked but never said so - the strip switches
 * views now, and one of the views needs a name.
 */
function fillCustomJumps() {
  const box = qs('.picker__jumps--custom', panel);
  if (!box) return;
  if (!sets.length) {
    releaseMedia(box);
    clear(box);
    return;
  }

  // Appending, as in renderCustomSet: the strip updates on every stickers
  // event, and recreating three dozen icons five times a second meant
  // throwing away the previous players and videos each time.
  let standard = qs('.picker__jump--standard', box);
  if (!standard) {
    standard = el('button', {
      class: 'picker__jump picker__jump--standard',
      type: 'button',
      title: 'Standard emoji',
      onclick: () => showSet(null),
    }, icon('smile'));
    box.prepend(standard);
  }
  standard.classList.toggle('is-active', shownSet === null);

  const have = new Map(qsa('.picker__jump--custom', box).map((b) => [b.dataset.set, b]));
  let prev = standard;
  for (const set of sets) {
    let button = have.get(set.id);
    have.delete(set.id);
    if (!button) {
      button = el('button', {
        class: 'picker__jump picker__jump--custom',
        type: 'button',
        dataset: { set: set.id },
        onclick: () => showSet(set.id),
      });
    }
    if (prev.nextSibling !== button) prev.after(button);
    button.title = set.title;
    button.classList.toggle('is-active', shownSet === set.id);
    const key = setIconKey(set);
    if (button.dataset.art !== key) {
      releaseMedia(button);
      clear(button).append(setIcon(set));
      button.dataset.art = key;
    }
    prev = button;
  }
  // Sets the account no longer has.
  for (const button of have.values()) {
    releaseMedia(button);
    button.remove();
  }
}

async function fillCustom() {
  let data;
  try {
    data = await hooks.load?.('emoji.sets');
  } catch {
    return;   // no custom emoji is a perfectly good panel
  }
  if (!panel?.matches(':popover-open')) return;

  sets = data?.sets ?? [];
  fillCustomJumps();
  // Redraw the set on screen, if its emoji have just arrived. The rest
  // are not in the document and have nothing to redraw.
  if (shownSet !== null) {
    const set = sets.find((x) => x.id === shownSet);
    if (!set) showSet(null);
    else renderCustomSet(qs('.picker__custom', panel), set);
  }
}

function pickEmoji(char) {
  remember(char);
  if (oneShot) {
    const answer = oneShot;
    oneShot = null;
    hide();
    answer(char);
    return;
  }
  hooks.insert?.(char);
  // Deliberately stays open: picking emoji comes in runs, and closing
  // after every one is the thing that makes a picker annoying.
  refreshRecent();
}

function emojiCell(item) {
  const cell = el('button', {
    class: 'picker__cell',
    type: 'button',
    title: item.n,
    onclick: (event) => pickEmoji(event.currentTarget.textContent),
  }, toned(item));
  if (item.t) toneCells.push([cell, item]);
  return cell;
}

function refreshRecent() {
  const box = qs('.picker__recent', panel);
  if (!box) return;
  const list = readStore(RECENT_KEY, []);
  box.hidden = list.length === 0;
  clear(qs('.picker__grid', box)).append(
    ...list.map((char) => el('button', {
      class: 'picker__cell', type: 'button', onclick: () => pickEmoji(char),
    }, char)),
  );
}

/** Rewrites every toned cell in place - all a tone change ever does. */
function applyTone() {
  for (const [cell, item] of toneCells) cell.textContent = toned(item);
  for (const [i, btn] of qsa('.picker__tone', panel).entries()) {
    btn.classList.toggle('is-active', i === tone);
  }
}

function buildEmoji(body) {
  const sections = el('div', { class: 'picker__sections' });

  sections.append(el('section', { class: 'picker__section picker__recent', hidden: true },
    el('h3', { class: 'picker__heading' }, 'Recently used'),
    el('div', { class: 'picker__grid' })));

  for (const group of catalogue.groups) {
    sections.append(el('section', {
      class: 'picker__section', dataset: { group: group.id },
    },
    el('h3', { class: 'picker__heading' }, group.name),
    el('div', { class: 'picker__grid' }, ...group.items.map(emojiCell))));
  }

  // The custom sets sit after the Unicode groups and before the
  // search results, so scrolling past the end of the standard emoji
  // runs into them the way it does in the official client.
  const custom = el('div', { class: 'picker__custom', hidden: true });

  const results = el('section', { class: 'picker__section picker__results', hidden: true },
    el('h3', { class: 'picker__heading' }, 'Search results'),
    el('div', { class: 'picker__grid' }));

  body.append(sections, custom, results);
  buildStrip();
  refreshRecent();
  applyTone();
}

/**
 * The row of group and set buttons along the bottom.
 *
 * It is a child of the PANEL, not of the scrolling body. Inside the
 * body it was `position: sticky; bottom: 0`, which pins an element to
 * the bottom of the scroller only while there is enough content to
 * scroll: a short set left it floating halfway up the panel. Outside
 * the scroller there is nothing to float - it is simply the last row
 * of the panel.
 */
function buildStrip() {
  if (qs('.picker__strip', panel)) return;
  const strip = el('div', { class: 'picker__strip' },
    // Filled once the account's custom sets are known - see
    // fillCustomJumps.
    el('div', { class: 'picker__jumps picker__jumps--custom' }),
    ...catalogue.groups.map((group) => el('button', {
      class: 'picker__jump',
      type: 'button',
      title: group.name,
      onclick: () => {
        showSet(null);
        qs(`[data-group="${group.id}"]`, panel)?.scrollIntoView({ block: 'start' });
      },
    }, group.icon)));
  sideScroll(strip);
  panel.append(strip);
}

/**
 * Brings the button for what is on screen into the middle of the
 * strip, so the neighbours on both sides are visible and the strip
 * reads as a place you are somewhere in.
 */
function centreJump(button) {
  if (!button) return;
  const strip = button.closest('.picker__strip');
  if (!strip) return;

  // Measured off the rectangles rather than offsetLeft: the button's
  // offsetParent is the panel (a popover, and therefore positioned),
  // so offsetLeft is a layout position that ignores how far the strip
  // is already scrolled. The rects are what is actually on screen.
  const seen = strip.getBoundingClientRect();
  const mine = button.getBoundingClientRect();
  const to = strip.scrollLeft + (mine.left - seen.left)
    - (seen.width - mine.width) / 2;

  // Plainly, not smoothly. `behavior: 'smooth'` does nothing at all in
  // this WebView - measured: a plain scrollTo moved the strip to 200,
  // the same call with behavior smooth left it at 0 - and a scroll
  // that silently does not happen is worse than one without easing.
  strip.scrollLeft = Math.max(0, to);
}

/**
 * Search is over the Unicode names, which is what emoji.json carries -
 * "grinning face", "flag: Germany". Matching hides the groups and fills
 * one flat section instead of touching 1895 cells, because the result
 * of a query is nearly always short.
 */
function runEmojiSearch(text) {
  const words = text.trim().toLowerCase().split(/\s+/).filter(Boolean);
  // The search is over Unicode names, so it answers from the standard
  // groups - being inside a custom set while typing one would show a
  // result that is not there.
  if (words.length && shownSet !== null) showSet(null);
  const sections = qs('.picker__sections', panel);
  const results = qs('.picker__results', panel);
  const strip = qs('.picker__strip', panel);

  if (!words.length) {
    sections.hidden = shownSet !== null;
    results.hidden = true;
    strip.hidden = false;
    return;
  }

  const hits = [];
  for (const group of catalogue.groups) {
    for (const item of group.items) {
      const name = item.n.toLowerCase();
      if (words.every((w) => name.includes(w))) hits.push(item);
      if (hits.length >= 200) break;
    }
  }

  sections.hidden = true;
  strip.hidden = true;
  results.hidden = false;
  const grid = clear(qs('.picker__grid', results));
  if (!hits.length) grid.append(el('p', { class: 'picker__empty' }, 'Nothing matches'));
  else grid.append(...hits.map(emojiCell));
}

// ------------------------------------------------- stickers and GIFs
/**
 * One sticker, in whichever of the three sticker formats it arrived -
 * the same three util/emoji.js already handles, for the same reason:
 * a sticker and a custom emoji are the same kind of file.
 */
// ------------------------------------------------------ still frames
// A frame instead of a player: the player (or video) draws one frame and is
// destroyed at once, and an <img> with that frame stays in the cell. Lazily
// — only when the cell nears the visible area, and no more than
// STILL_PARALLEL at once: a set of a hundred emoji would otherwise raise a
// hundred players at once for one frame each.
//
// Ready frames are cached by file address as data URLs. The Stickers tab,
// the set and the strip are rebuilt on stickers events (up to five a second
// while the files download), and without a cache every rebuild blanked the
// tiles and drew their frames anew.
//
// CSS px of the frame: an emoji cell is from 32px, a sticker tile from 68px
// (the column minimums in blocks/_picker.scss), and both can stretch to
// about one and a half of the minimum.
const STILL_SIZE = { emoji: 40, tile: 100, gif: 160 };
const STILL_PARALLEL = 4;
// A frame not ready within this time is dropped: otherwise a stuck file
// would hold a queue slot forever, and four of them — the whole queue.
const STILL_TIMEOUT_MS = 8000;
const STILL_CACHE_MAX = 300;
const stillCache = new Map();   // kind:url -> data URL; the Map order is age
const stillJobs = new Map();    // <img> -> { item, kind }, not yet scrolled into view
const stillQueue = [];
let stillRunning = 0;
let lazy = null;

const stillKey = (item, kind) => `${kind}:${item.url}`;

function rememberStill(key, src) {
  stillCache.delete(key);
  stillCache.set(key, src);
  if (stillCache.size > STILL_CACHE_MAX) stillCache.delete(stillCache.keys().next().value);
}

function lazyObserver() {
  if (!lazy) {
    // The root is the viewport, not the panel body: the set icons in the
    // strip lie outside the body. The observer still accounts for the
    // body's scroll — a cell clipped by it does not intersect.
    lazy = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const job = stillJobs.get(entry.target);
        lazy.unobserve(entry.target);
        stillJobs.delete(entry.target);
        if (job) stillQueue.push([entry.target, job]);
      }
      pumpStill();
    }, { rootMargin: '200px' });
  }
  return lazy;
}

/**
 * The frame as a picture address, or null.
 *
 * A sticker in a tile — SVG (stillSvg): at this size the canvas renderer's
 * flaw with gradients shows. Emoji — the canvas renderer on a scratch
 * canvas (stillSticker), webm — the video's first frame on a scratch
 * canvas. The canvas is converted to PNG at once and released.
 */
async function makeStill(item, kind) {
  const late = new Promise((_, reject) => {
    setTimeout(() => reject(new Error(`still timeout (${item.format})`)), STILL_TIMEOUT_MS);
  });
  if (item.format === 'tgs' && kind === 'tile') return Promise.race([stillSvg(item.url), late]);
  const canvas = document.createElement('canvas');
  const ok = await Promise.race([
    item.format === 'webm' || item.format === 'mp4'
      ? videoStill(canvas, item.url, STILL_SIZE[kind])
      : stillSticker(canvas, item.url, STILL_SIZE[kind]),
    late,
  ]);
  return ok ? canvas.toDataURL('image/png') : null;
}

function pumpStill() {
  while (stillRunning < STILL_PARALLEL && stillQueue.length) {
    const [img, { item, kind }] = stillQueue.shift();
    if (!img.isConnected) continue;
    const key = stillKey(item, kind);
    // It may have been drawn while the cell stood in the queue.
    const ready = stillCache.get(key);
    if (ready) {
      img.src = ready;
      continue;
    }
    stillRunning += 1;
    makeStill(item, kind).then((src) => {
      if (!src) return;
      rememberStill(key, src);
      if (img.isConnected) img.src = src;
    }).catch((err) => {
      // Not silently: that is how the canvas SecurityError hid.
      console.error('picker still', item.url, err);
    }).finally(() => {
      stillRunning -= 1;
      pumpStill();
    });
  }
}

/** The first webm frame onto the canvas; the video is released right after. */
function videoStill(canvas, url, cssSize) {
  return new Promise((resolve) => {
    const video = document.createElement('video');
    // The file is from the server, and the page from its own address
    // (https://fptg.example): without CORS the frame "taints" the canvas,
    // and toDataURL throws SecurityError — the emoji cells of webm sets
    // stayed empty. The server sends CORS headers.
    video.crossOrigin = 'anonymous';
    video.muted = true;
    video.playsInline = true;
    video.preload = 'auto';
    let drawn = false;
    let timer = 0;
    const done = () => {
      clearTimeout(timer);
      video.removeAttribute('src');
      video.load();
      resolve(drawn);
    };
    // A video that never gave a frame is released by itself rather than
    // hanging as a download (makeStill has dropped the wait by then).
    timer = setTimeout(done, STILL_TIMEOUT_MS);
    video.addEventListener('loadeddata', () => {
      const vw = video.videoWidth;
      const vh = video.videoHeight;
      if (vw && vh) {
        // The canvas — in the proportions of the frame fitted into cssSize:
        // a GIF frame is not square, and the margins around it would show in the tile.
        const size = Math.round(cssSize * (window.devicePixelRatio || 1));
        const k = Math.min(size / vw, size / vh);
        canvas.width = Math.max(1, Math.round(vw * k));
        canvas.height = Math.max(1, Math.round(vh * k));
        canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
        drawn = true;
      }
      done();
    }, { once: true });
    video.addEventListener('error', done, { once: true });
    video.src = url;
  });
}

function stillNode(item, kind, cls = 'picker__sticker') {
  const img = el('img', { class: `${cls} picker__still`, alt: item.emoji ?? '' });
  const ready = stillCache.get(stillKey(item, kind));
  if (ready) {
    img.src = ready;
    return img;
  }
  stillJobs.set(img, { item, kind });
  lazyObserver().observe(img);
  return img;
}

/**
 * opts.still — a still frame: true or 'emoji' — for custom emoji cells and
 * set icons, 'tile' — for sticker tiles. Without it — a live player (the
 * one under the cursor).
 *
 * A video is not autoplay: offscreen starts and stops it by visibility, and
 * one that went far past the scroll edge gives up its decoder.
 */
function stickerNode(item, opts = {}) {
  if (opts.still && (item.format === 'tgs' || item.format === 'webm')) {
    return stillNode(item, opts.still === 'tile' ? 'tile' : 'emoji');
  }
  if (item.format === 'webm') {
    const video = el('video', {
      class: 'picker__sticker', src: item.url,
      loop: true, muted: true, playsInline: true, preload: 'metadata',
    });
    holdVideo(video, item.url, 'loop');
    return video;
  }
  if (item.format === 'tgs') {
    const frame = el('span', { class: 'picker__sticker picker__sticker--lottie' });
    playSticker(frame, item.url);
    return frame;
  }
  return el('img', {
    class: 'picker__sticker', src: item.url, alt: item.emoji ?? '',
    loading: 'lazy', decoding: 'async',
  });
}

function sendMedia(kind, fileId) {
  hooks.send?.({ kind, fileId });
  hide();
}

/**
 * An unloaded set asks the server for its stickers only once it is
 * actually on screen.
 *
 * That laziness is the server's design, not a nicety here: a set is a
 * request of its own plus a file per sticker, and an account with
 * forty installed sets would otherwise fetch tens of thousands of
 * files the moment the panel opened. The answer comes back empty and
 * the real content arrives later as a 'stickers' event.
 */
function watchSet(section, id) {
  const seen = new IntersectionObserver((entries) => {
    if (!entries.some((e) => e.isIntersecting)) return;
    seen.disconnect();
    hooks.load?.('stickers.set', { id }).catch(() => { /* the panel stays as it is */ });
  }, { root: qs('.picker__body', panel), rootMargin: '200px' });
  seen.observe(section);
}

function buildStickers(body, data) {
  if (!data?.sets?.length) {
    // "ready" is the server saying its first answer from Telegram has
    // come back. Without it an empty list would read as "you have no
    // stickers" during the second it takes to find out that you do.
    let word = 'Loading…';
    if (data?.ready) word = data.query ? 'Nothing found' : 'No sticker sets yet';
    body.append(el('p', { class: 'picker__empty' }, word));
    return;
  }
  for (const set of data.sets) {
    // A set that has come back with nothing in it is not loading, it is
    // empty - and an empty section under its own heading says nothing
    // worth a line. Only a set that HAS stickers whose files have not
    // arrived is still loading.
    if (set.loaded && !set.stickers.length) continue;

    // As with custom emoji: a frame in the tile, a live player only under
    // the cursor. The tab used to hold an SVG player for every sticker of
    // all the sets shown.
    const cells = set.stickers.filter((s) => s.url).map((s) => el('button', {
      class: 'picker__tile',
      type: 'button',
      title: s.emoji || set.title,
      onclick: () => sendMedia('sticker', s.fileId),
      onpointerenter: (event) => goLive(event.currentTarget, s),
      onpointerleave: (event) => stopLive(event.currentTarget),
    }, stickerNode(s, { still: 'tile' })));

    const section = el('section', { class: 'picker__section' },
      el('h3', { class: 'picker__heading' }, set.title),
      cells.length
        ? el('div', { class: 'picker__tiles' }, ...cells)
        : el('p', { class: 'picker__empty' }, 'Loading…'));
    body.append(section);
    if (!set.loaded) watchSet(section, set.id);
  }

  // Every set was skipped, so the answer really is "nothing".
  if (!body.firstChild) {
    body.append(el('p', { class: 'picker__empty' },
      data.query ? 'Nothing found' : 'No sticker sets yet'));
  }
}

/**
 * What one tile can show.
 *
 * Telegram gives only SOME saved animations a thumbnail that moves:
 * measured on a real account, 134 of them came back with 68 mpeg4
 * thumbnails, 60 still jpegs and 6 with no thumbnail at all.
 *
 * A tile is a FRAME, as with stickers: every visible tile used to be its
 * own playing <video>, and there are over a hundred in the panel. The frame
 * is a still preview (jpeg), and without one — the video's first frame
 * converted to a picture (stillNode, the frame cache). Only the tile under
 * the cursor plays — with what moves: the animation itself, and until it
 * arrives — the moving preview.
 */
const gifLive = (g) => g.playUrl || (g.thumbFormat === 'mpeg4' ? g.url : '') || '';

function gifStill(g) {
  if (g.url && g.thumbFormat !== 'mpeg4') return { kind: 'img', url: g.url };
  const video = gifLive(g);
  if (video) return { kind: 'video', url: video };
  return null;
}

const gifKey = (g) => {
  const still = gifStill(g);
  return still ? `${still.kind}:${still.url}` : '';
};

function gifNode(g) {
  const still = gifStill(g);
  if (!still) return el('span', { class: 'picker__gif picker__still' });
  if (still.kind === 'img') {
    return el('img', {
      class: 'picker__gif picker__still', src: still.url, alt: '',
      loading: 'lazy', decoding: 'async',
    });
  }
  return stillNode({ format: 'mp4', url: still.url }, 'gif', 'picker__gif');
}

const gifTileItem = (tile) => ({ format: 'mp4', url: tile.dataset.live || '' });

/**
 * Plays what is on screen and pauses what is not, and asks the server
 * for the animation of any tile that has nothing moving to show yet.
 *
 * Both halves matter at this scale: a hundred and thirty autoplaying
 * videos is not a preview panel, and fetching a hundred and thirty
 * video files to build one is worse.
 */
function watchGifs(box) {
  const seen = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      entry.target.dataset.seen = entry.isIntersecting ? 'yes' : 'no';
      if (!entry.isIntersecting || entry.target.dataset.still !== 'yes') continue;
      delete entry.target.dataset.still;
      hooks.load?.('gifs.ensure', { fileId: Number(entry.target.dataset.file) })
        .catch(() => { /* the still frame stays */ });
    }
  }, { root: qs('.picker__body', panel), rootMargin: '150px' });
  for (const tile of qsa('.picker__tile', box)) seen.observe(tile);
}

/**
 * Swaps a still tile for its animation now that the file has arrived,
 * without touching the rest.
 *
 * A plain rebuild would be shorter, and wrong: the files come in one
 * at a time over several seconds, and every rebuild restarts every
 * video already playing. Answers false when the tiles on screen no
 * longer match the list, which is when a rebuild is the right answer.
 */
function upgradeGifs(pane, items) {
  const box = qs('.picker__tiles', pane);
  if (!box || box.children.length !== items.length) return false;

  const tiles = new Map([...box.children].map((t) => [t.dataset.file, t]));
  if (items.some((g) => !tiles.has(String(g.fileId)))) return false;

  for (const g of items) {
    const tile = tiles.get(String(g.fileId));
    const key = gifKey(g);
    // Compare what the tile HAS against what is available now. The
    // first version only looked for an arriving animation, so a tile
    // whose thumbnail had just downloaded kept its blank placeholder
    // for ever - which is exactly what a search full of results looked
    // like. Comparing the source also means an unchanged tile is left
    // alone, so a video that is already playing is not restarted.
    // What to play under the cursor — always the freshest: the animation
    // arrives later than the preview, and the tile's frame need not change.
    tile.dataset.live = gifLive(g);
    if (gifLive(g)) tile.dataset.still = 'no';
    if (!key || tile.dataset.src === key) continue;
    tile.dataset.src = key;
    // Only the frame changes; the live video under the cursor, if there is
    // one, stays.
    const old = qs('.picker__still', tile);
    releaseMedia(old);
    if (old) old.replaceWith(gifNode(g));
    else tile.prepend(gifNode(g));
  }
  return true;
}

function buildGifs(body, data) {
  const items = data?.items ?? [];
  if (!items.length) {
    let word = 'Loading…';
    if (data?.ready) word = data.query ? 'Nothing found' : 'No saved GIFs yet';
    body.append(el('p', { class: 'picker__empty' }, word));
    return;
  }
  const box = el('div', { class: 'picker__tiles picker__tiles--wide' },
    ...items.map((g) => el('button', {
      class: 'picker__tile',
      type: 'button',
      title: 'Send this GIF',
      dataset: {
        file: String(g.fileId),
        src: gifKey(g),
        live: gifLive(g),
        still: gifLive(g) ? 'no' : 'yes',
      },
      onclick: () => sendMedia('animation', g.fileId),
      onpointerenter: (event) => goLive(event.currentTarget, gifTileItem(event.currentTarget)),
      onpointerleave: (event) => stopLive(event.currentTarget),
    }, gifNode(g))));
  body.append(box);
  watchGifs(box);
}

// ------------------------------------------------------------- tabs
function paneFor(name) {
  if (!panes[name]) {
    panes[name] = el('div', { class: 'picker__pane' });
    qs('.picker__body', panel).append(panes[name]);
  }
  for (const [key, node] of Object.entries(panes)) node.hidden = key !== name;
  return panes[name];
}

async function showTab(name) {
  tab = name;
  for (const btn of qsa('.picker__tab', panel)) {
    btn.classList.toggle('is-active', btn.dataset.tab === name);
  }
  // The search box stays on every tab - all three search something -
  // but it says what, and the skin tones belong to the emoji tab
  // alone: nothing in a sticker set has one.
  const box = qs('.picker__query', panel);
  box.placeholder = PLACEHOLDER[name];
  qs('.picker__tones', panel).hidden = name !== 'emoji';
  // The strip navigates the emoji groups and sets, and there is
  // nothing for it to navigate on the other two tabs.
  const strip = qs('.picker__strip', panel);
  if (strip) strip.hidden = name !== 'emoji';

  const pane = paneFor(name);
  if (name === 'emoji') {
    if (!pane.firstChild) buildEmoji(pane);
    // The grid is built once and kept, so whatever the last emoji
    // search left behind is still on it.
    runEmojiSearch(query);
    return;
  }

  // "Loading" only when there is nothing to show yet. A refresh keeps
  // what is on screen until the new content is ready - otherwise every
  // arriving sticker file would blank the panel for a frame, and they
  // arrive by the hundred.
  if (!pane.firstChild) {
    pane.append(el('p', { class: 'picker__empty' }, 'Loading…'));
  }
  // Searching stickers and GIFs is the SERVER's job, not a filter
  // over what happens to be loaded: stickers come back from the whole
  // of the account's installed sets, and GIFs from Telegram's search
  // bot, neither of which is in the page.
  const what = name === 'stickers' ? 'stickers.list' : 'gifs.list';
  const asked = query;
  try {
    const data = await hooks.load?.(what, { query: asked });
    // Switched away, or typed on, while it was in flight.
    if (tab !== name || query !== asked) return;
    if (name === 'gif' && upgradeGifs(pane, data?.items ?? [])) return;
    releaseMedia(pane);
    clear(pane);
    if (name === 'stickers') buildStickers(pane, data);
    else buildGifs(pane, data);
  } catch (err) {
    if (tab !== name || query !== asked) return;
    releaseMedia(pane);
    clear(pane).append(el('p', { class: 'picker__empty' }, String(err.message ?? err)));
  }
}

/**
 * A tab button. Clears the query, because each tab searches something
 * of its own and carrying "smile" from emoji into GIFs would ask the
 * search bot a question nobody typed.
 */
function switchTab(name) {
  window.clearTimeout(queryTimer);
  query = '';
  const box = qs('.picker__query', panel);
  if (box) box.value = '';
  showTab(name).catch(console.error);
}

/**
 * One box, three searches. The emoji one runs here, over a list that
 * is already in the page; the other two are round trips, so they wait
 * for a pause in the typing first.
 */
function onQuery(text) {
  query = text;
  window.clearTimeout(queryTimer);
  if (tab === 'emoji') {
    runEmojiSearch(text);
    return;
  }
  queryTimer = window.setTimeout(() => {
    showTab(tab).catch(console.error);
  }, 300);
}

/**
 * The server says a sticker set or a saved animation changed - a set
 * that was asked for has arrived, or another client installed one.
 *
 * Only ever redraws the tab that is actually showing, and only while
 * the panel is open: the emoji tab has nothing to do with any of this,
 * and a closed panel rebuilds from scratch on its next opening anyway.
 * The scroll position is carried over by hand, because the pane is
 * replaced wholesale and would otherwise jump to the top every time a
 * file lands.
 */
export function pickerChanged() {
  if (!panel?.matches(':popover-open')) return;
  if (tab === 'emoji') {
    // The standard emoji never change; the custom ones arrive set by
    // set and file by file, exactly like stickers. In both modes — for a
    // reaction and for the composer: the first emoji.sets answer comes
    // without the sets' contents, and everything else arrives only here.
    fillCustom().catch(console.error);
    return;
  }
  const body = qs('.picker__body', panel);
  const top = body.scrollTop;
  showTab(tab).then(() => { body.scrollTop = top; }).catch(console.error);
}

// ------------------------------------------------------ open / close
function hide() {
  try { panel?.hidePopover(); } catch { /* already closed */ }
}

function build() {
  const head = el('div', { class: 'picker__head' },
    el('label', { class: 'picker__search' },
      icon('search', 'picker__search-icon'),
      el('input', {
        class: 'picker__query', type: 'search', placeholder: PLACEHOLDER.emoji,
        oninput: (event) => onQuery(event.currentTarget.value),
      })),
    el('div', { class: 'picker__tones' },
      ...TONE_SWATCH.map((swatch, i) => el('button', {
        class: `picker__tone${i === tone ? ' is-active' : ''}`,
        type: 'button',
        title: i === 0 ? 'Default skin tone' : `Skin tone ${i}`,
        onclick: () => {
          tone = i;
          writeStore(TONE_KEY, tone);
          applyTone();
        },
      }, swatch))));

  const node = el('div', { class: 'picker', popover: 'auto' },
    el('div', { class: 'picker__tabs' },
      ...[['emoji', 'Emoji'], ['stickers', 'Stickers'], ['gif', 'GIF']]
        .map(([id, label]) => el('button', {
          class: `picker__tab${id === 'emoji' ? ' is-active' : ''}`,
          type: 'button',
          dataset: { tab: id },
          onclick: () => switchTab(id),
        }, label))),
    head,
    el('div', { class: 'picker__body' }));

  node.addEventListener('toggle', (event) => {
    if (event.newState !== 'closed') return;
    anchor?.classList.remove('is-picker-anchor');
    // Dismissed without answering: the question lapses, and the panel
    // goes back to belonging to the composer.
    oneShot = null;
    anchor = mounted;
    node.classList.remove('picker--emoji-only');
    // A closed panel holds nothing alive. The open custom set, the set
    // icons and the Stickers/GIF tabs are re-requested on the next open
    // anyway; the ordinary emoji grid is text, it stays (it is expensive to
    // build and costs almost no memory).
    renderCustomSet(qs('.picker__custom', node), null);
    const jumps = qs('.picker__jumps--custom', node);
    releaseMedia(jumps);
    if (jumps) clear(jumps);
    for (const [name, pane] of Object.entries(panes)) {
      if (name === 'emoji') continue;
      releaseMedia(pane);
      clear(pane);
    }
  });
  document.body.append(node);
  return node;
}

async function toggle() {
  if (panel?.matches(':popover-open')) {
    hide();
    return;
  }
  if (!catalogue) {
    // One fetch for the life of the page. Until it lands the button
    // simply does not open - a spinner for a 95 KB local file would be
    // on screen for less time than it takes to notice.
    catalogue = await fetch(DATA_URL).then((r) => r.json());
    tone = Number(readStore(TONE_KEY, 0)) || 0;
  }
  if (!panel) panel = build();

  anchor.classList.add('is-picker-anchor');
  panel.showPopover();
  markPopDirection(panel, anchor);
  await showTab(tab);
  if (tab === 'emoji') qs('.picker__query', panel)?.focus();
  // Custom emoji sets — both for a reaction and for the composer. Asked on
  // every open: what the account has installed may have changed.
  fillCustom().catch(console.error);
}

/**
 * hooks: { insert(text), insertCustom(id, emoji), send({kind, fileId}),
 *          load(cmd, args) }
 *
 * The panel asks for data through `load` and never reaches for the
 * network itself, the same division every other ui/ module keeps: main
 * .js owns the socket, the views own the DOM.
 */
export function mountPicker(button, options) {
  anchor = button;
  mounted = button;
  hooks = options ?? {};
  button.addEventListener('click', () => { toggle().catch(console.error); });
}

/**
 * Opens the panel to answer one question - which emoji? - and calls
 * back with the answer instead of typing it into the composer.
 *
 * What the reaction strip's chevron does. The panel hangs off whatever
 * node is passed, because the button that opened it has by then gone
 * with its menu, and an anchor outside the document positions nothing.
 */
export function openEmojiPicker(node, onPick) {
  oneShot = onPick;
  anchor?.classList.remove('is-picker-anchor');
  anchor = node;
  tab = 'emoji';
  toggle().then(() => {
    panel?.classList.add('picker--emoji-only');
    // The standard emoji are what the panel opens on - the custom sets
    // are a click away in the strip, not in front of them. The sets
    // themselves are pulled in by toggle().
    showSet(null);
  }).catch(console.error);
}
