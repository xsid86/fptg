import { el, clear, qs, qsa } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { playSticker } from './sticker.js';

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
let hooks = {};
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
function pickEmoji(char) {
  remember(char);
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

  const results = el('section', { class: 'picker__section picker__results', hidden: true },
    el('h3', { class: 'picker__heading' }, 'Search results'),
    el('div', { class: 'picker__grid' }));

  const strip = el('div', { class: 'picker__strip' },
    ...catalogue.groups.map((group) => el('button', {
      class: 'picker__jump',
      type: 'button',
      title: group.name,
      onclick: () => qs(`[data-group="${group.id}"]`, panel)
        ?.scrollIntoView({ block: 'start' }),
    }, group.icon)));

  body.append(sections, results, strip);
  refreshRecent();
  applyTone();
}

/**
 * Search is over the Unicode names, which is what emoji.json carries -
 * "grinning face", "flag: Germany". Matching hides the groups and fills
 * one flat section instead of touching 1895 cells, because the result
 * of a query is nearly always short.
 */
function runEmojiSearch(text) {
  const words = text.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const sections = qs('.picker__sections', panel);
  const results = qs('.picker__results', panel);
  const strip = qs('.picker__strip', panel);

  if (!words.length) {
    sections.hidden = false;
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
  if (tab === 'emoji') return;
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
    if (event.newState === 'closed') anchor.classList.remove('is-picker-anchor');
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
  hooks = options ?? {};
  button.addEventListener('click', () => { toggle().catch(console.error); });
}
