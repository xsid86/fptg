import { el, clear, qs, qsa } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { playSticker } from './sticker.js';
import { sideScroll } from '../util/sidescroll.js';

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
// wrote assets/data/emoji.json: Unicode's emoji-test.txt crossed with
// emoji_atlas.dat, the very atlas emojiassets.pas draws from. So the
// panel can only offer an emoji the native window can also draw - the
// two views never disagree about what a message looks like, which is
// the whole point of keeping them side by side.
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

/** The variant of an emoji for the tone currently chosen. */
const toned = (item) => (tone > 0 && item.t ? item.t[tone - 1] : item.e);

// ------------------------------------------------------------ emoji
/**
 * A Premium custom emoji, answered as an object rather than a
 * character - it has no character to be.
 *
 * Only ever offered while the panel is answering "which emoji?" for a
 * reaction. Typing one into the composer would mean writing a text
 * ENTITY, and this composer is a plain textarea whose text is parsed
 * as MarkdownV2 on the way out; the escaper would turn the markup for
 * one back into literal punctuation. So the custom sets are built only
 * in that mode, and the stylesheet keeps them out of the other.
 */
function pickCustom(item) {
  if (!oneShot) return;
  const answer = oneShot;
  oneShot = null;
  hide();
  answer({ customEmojiId: item.id, emoji: item.emoji });
}

const customCell = (item) => el('button', {
  class: 'picker__cell picker__cell--custom',
  type: 'button',
  title: item.emoji || 'Custom emoji',
  onclick: () => pickCustom(item),
}, stickerNode(item));

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

function renderCustomSet(box, set) {
  clear(box);
  if (!set) return;
  const cells = set.emoji.filter((e) => e.url).map(customCell);
  box.append(el('section', { class: 'picker__section' },
    el('h3', { class: 'picker__heading' }, set.title),
    cells.length
      ? el('div', { class: 'picker__grid' }, ...cells)
      : el('p', { class: 'picker__empty' }, 'Loading…')));
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
    clear(box);
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
function setIcon(set) {
  const art = set.cover?.url ? set.cover : set.emoji.find((e) => e.url);
  if (art) return stickerNode(art);
  return set.cover?.emoji || set.emoji[0]?.emoji || set.title.slice(0, 1);
}

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
  clear(box);
  if (!sets.length) return;

  box.append(el('button', {
    class: `picker__jump picker__jump--standard${shownSet === null ? ' is-active' : ''}`,
    type: 'button',
    title: 'Standard emoji',
    onclick: () => showSet(null),
  }, icon('smile')));

  for (const set of sets) {
    box.append(el('button', {
      class: `picker__jump picker__jump--custom${shownSet === set.id ? ' is-active' : ''}`,
      type: 'button',
      title: set.title,
      dataset: { set: set.id },
      onclick: () => showSet(set.id),
    }, setIcon(set)));
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
    // Filled once the account's custom sets are known, and only while
    // the panel is picking a reaction - see fillCustomJumps.
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
function stickerNode(item) {
  if (item.format === 'webm') {
    return el('video', {
      class: 'picker__sticker', src: item.url,
      autoplay: true, loop: true, muted: true, playsInline: true,
    });
  }
  if (item.format === 'tgs') {
    const frame = el('span', { class: 'picker__sticker picker__sticker--lottie' });
    playSticker(frame, item.url);
    return frame;
  }
  return el('img', { class: 'picker__sticker', src: item.url, alt: item.emoji ?? '' });
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

    const cells = set.stickers.filter((s) => s.url).map((s) => el('button', {
      class: 'picker__tile',
      type: 'button',
      title: s.emoji || set.title,
      onclick: () => sendMedia('sticker', s.fileId),
    }, stickerNode(s)));

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

const gifVideo = (src) => el('video', {
  class: 'picker__gif', src,
  loop: true, muted: true, playsInline: true,
});

/**
 * What one tile can show, best first.
 *
 * Telegram gives only SOME saved animations a thumbnail that moves:
 * measured on a real account, 134 of them came back with 68 mpeg4
 * thumbnails, 60 still jpegs and 6 with no thumbnail at all. So a
 * still frame is never the whole answer - for the rest the animation
 * itself is what has to be fetched, which is what the official clients
 * do as well. Until it arrives the still frame holds the place.
 */
const gifKey = (g) => {
  if (g.playUrl) return `p${g.playUrl}`;
  if (g.url) return `${g.thumbFormat === 'mpeg4' ? 'v' : 'i'}${g.url}`;
  return '';
};

function gifNode(g) {
  if (g.playUrl) return gifVideo(g.playUrl);
  if (g.thumbFormat === 'mpeg4' && g.url) return gifVideo(g.url);
  if (g.url) return el('img', { class: 'picker__gif', src: g.url, alt: '' });
  return el('span', { class: 'picker__gif' });
}

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
      const video = qs('video', entry.target);
      if (video) {
        if (entry.isIntersecting) video.play().catch(() => { /* not fatal */ });
        else video.pause();
      }
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
    if (!key || tile.dataset.src === key) continue;
    tile.dataset.src = key;
    if (g.playUrl || g.thumbFormat === 'mpeg4') tile.dataset.still = 'no';
    tile.replaceChildren(gifNode(g));
    // Only what the viewer is actually looking at starts playing; the
    // observer sees to the rest when they scroll into view.
    if (tile.dataset.seen === 'yes') qs('video', tile)?.play().catch(() => {});
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
        still: g.playUrl || g.thumbFormat === 'mpeg4' ? 'no' : 'yes',
      },
      onclick: () => sendMedia('animation', g.fileId),
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
    clear(pane);
    if (name === 'stickers') buildStickers(pane, data);
    else buildGifs(pane, data);
  } catch (err) {
    if (tab !== name || query !== asked) return;
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
    // set and file by file, exactly like stickers.
    if (panel.classList.contains('picker--emoji-only')) {
      fillCustom().catch(console.error);
    }
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
  await showTab(tab);
  if (tab === 'emoji') qs('.picker__query', panel)?.focus();
}

/**
 * hooks: { insert(text), send({kind, fileId}), load(cmd, args) }
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
    // are a click away in the strip, not in front of them.
    showSet(null);
    fillCustom().catch(console.error);
  }).catch(console.error);
}
