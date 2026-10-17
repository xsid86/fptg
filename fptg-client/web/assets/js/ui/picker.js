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
 * Отпускает всё тяжёлое внутри `root`: Lottie-плееры, видео (декодер и
 * буферы — только через снятие src и load()) и наблюдение offscreen.
 *
 * ВЫЗЫВАТЬ ДО clear(): после него узлы уже не внутри root, и найти их
 * будет нечем. Именно так панель и текла — clear() отцеплял узлы, а
 * плееры и видео жили дальше: несколько переключений наборов кастомных
 * эмодзи дали 2.6 ГБ у процесса WebView2.
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
 * Для реакции — ответ на вопрос «какой эмодзи?». В композере — вставка
 * сущностью (composer.insertCustomEmoji): поле (ui/editor.js) рисует его
 * картинкой и отправляет textEntityTypeCustomEmoji.
 * Панель при этом остаётся открытой, как и для обычных эмодзи.
 */
function pickCustom(item) {
  if (oneShot) {
    const answer = oneShot;
    oneShot = null;
    hide();
    answer({ customEmojiId: item.id, emoji: item.emoji });
    return;
  }
  // С адресом файла: поле ввода нарисует эмодзи картинкой сразу.
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
 * Живой плеер — только у ячейки под курсором, поверх её кадра, и
 * уничтожается, как только курсор ушёл. Так в любой момент в сетке
 * играет не больше одного эмодзи.
 */
function goLive(cell, item) {
  if (item.format !== 'tgs' && item.format !== 'webm' && item.format !== 'mp4') return;
  if (!item.url || cell.classList.contains('is-live')) return;
  // GIF — это mp4 без звука: под курсором просто играющее видео.
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
 * Рисует набор, ДОПИСЫВАЯ то, что пришло, а не перестраивая всё.
 *
 * Пока файлы набора качаются, событие stickers приходит до пяти раз в
 * секунду, и каждое раньше пересоздавало все ячейки — сотню плееров и
 * видео за раз, а старые оставались жить. Теперь готовая ячейка
 * остаётся как есть, новая встаёт на своё место по порядку набора, а
 * целиком набор сносится (с освобождением) только при смене набора.
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
 * Значок набора — НЕПОДВИЖНЫЙ: кадр, а не цикл. Три десятка наборов в
 * полоске, каждый своим плеером или видео, крутились всё время, пока
 * открыта панель, — ради значков, на которые никто не смотрит.
 */
function setIcon(set) {
  const art = setArt(set);
  if (art) return stickerNode(art, { still: true });
  return set.cover?.emoji || set.emoji[0]?.emoji || set.title.slice(0, 1);
}

/** Что сейчас нарисовано на кнопке набора — чтобы не перерисовывать то же. */
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

  // Дописывание, как и в renderCustomSet: полоска обновляется на каждое
  // событие stickers, и пересоздавать три десятка значков пять раз в
  // секунду значило каждый раз бросать прежние плееры и видео.
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
  // Наборы, которых у аккаунта больше нет.
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
// Кадр вместо плеера: плеер (или видео) рисует один кадр и сразу
// уничтожается, а в ячейке остаётся <img> с этим кадром. Лениво —
// только когда ячейка подошла к видимой области, и не больше
// STILL_PARALLEL одновременно: набор в сотню эмодзи иначе разом поднял
// бы сотню плееров ради одного кадра каждый.
//
// Готовые кадры кэшируются по адресу файла как data URL. Вкладка
// Stickers, набор и полоска перестраиваются на события stickers (до
// пяти в секунду, пока качаются файлы), и без кэша каждая перестройка
// гасила плитки и рисовала их кадры заново.
//
// CSS px кадра: ячейка эмодзи — от 32px, плитка стикера — от 68px
// (минимумы колонок в blocks/_picker.scss), а растянуться обе могут
// примерно до полутора минимумов.
const STILL_SIZE = { emoji: 40, tile: 100, gif: 160 };
const STILL_PARALLEL = 4;
// Кадр, не готовый за это время, бросается: иначе зависший файл держал
// бы слот очереди вечно, а четыре таких — всю очередь.
const STILL_TIMEOUT_MS = 8000;
const STILL_CACHE_MAX = 300;
const stillCache = new Map();   // kind:url -> data URL; порядок Map — давность
const stillJobs = new Map();    // <img> -> { item, kind }, ещё не дошедшие до вида
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
    // Корень — вьюпорт, а не тело панели: значки наборов в полоске
    // лежат вне тела. Прокрутку тела наблюдатель всё равно учитывает —
    // ячейка, срезанная им, не пересекается.
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
 * Кадр как адрес картинки, или null.
 *
 * Стикер в плитке — SVG (stillSvg): на этом размере изъян
 * canvas-рендерера с градиентами виден. Эмодзи — canvas-рендерер на
 * черновой холст (stillSticker), webm — первый кадр видео на черновой
 * холст. Холст сразу перегоняется в PNG и отпускается.
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
    // Мог дорисоваться, пока ячейка стояла в очереди.
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
      // Не молча: так SecurityError холста и прятался.
      console.error('picker still', item.url, err);
    }).finally(() => {
      stillRunning -= 1;
      pumpStill();
    });
  }
}

/** Первый кадр webm на холст; видео отпускается сразу после. */
function videoStill(canvas, url, cssSize) {
  return new Promise((resolve) => {
    const video = document.createElement('video');
    // Файл — с сервера, а страница — со своего адреса
    // (https://fptg.example): без CORS кадр «пачкает» холст, и
    // toDataURL бросает SecurityError — ячейки эмодзи наборов в webm
    // оставались пустыми. Сервер отдаёт заголовки CORS.
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
    // Видео, которое так и не дало кадра, отпускается само, а не висит
    // загрузкой (makeStill к этому времени уже бросил ожидание).
    timer = setTimeout(done, STILL_TIMEOUT_MS);
    video.addEventListener('loadeddata', () => {
      const vw = video.videoWidth;
      const vh = video.videoHeight;
      if (vw && vh) {
        // Холст — в пропорциях кадра, вписанного в cssSize: у GIF кадр
        // не квадратный, и поля вокруг него в плитке были бы видны.
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
 * opts.still — неподвижный кадр: true или 'emoji' — для ячеек
 * кастомных эмодзи и значков наборов, 'tile' — для плиток стикеров.
 * Без него — живой плеер (тот, что под курсором).
 *
 * Видео не autoplay: его запускает и останавливает offscreen по
 * видимости, а ушедшее далеко за край прокрутки отдаёт декодер.
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

    // Как у кастомных эмодзи: в плитке кадр, живой плеер — только под
    // курсором. Вкладка держала по SVG-плееру на каждый стикер всех
    // показанных наборов.
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
 * Плитка — КАДР, как у стикеров: каждая видимая плитка раньше была
 * своим играющим <video>, а их в панели за сотню. Кадр — неподвижное
 * превью (jpeg), а нет его — первый кадр видео, перегнанный в картинку
 * (stillNode, кэш кадров). Играет только плитка под курсором — тем, что
 * движется: самой анимацией, а пока её нет — движущимся превью.
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
    // Что играть под курсором — всегда самое свежее: анимация приходит
    // позже превью, а кадр плитки от этого меняться не обязан.
    tile.dataset.live = gifLive(g);
    if (gifLive(g)) tile.dataset.still = 'no';
    if (!key || tile.dataset.src === key) continue;
    tile.dataset.src = key;
    // Меняется только кадр; живое видео под курсором, если оно есть,
    // остаётся.
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
    // set and file by file, exactly like stickers. В обоих режимах —
    // и для реакции, и для композера: первый ответ emoji.sets приходит
    // без содержимого наборов, и всё остальное доезжает только сюда.
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
    // Закрытая панель не держит ничего живого. Открытый кастомный набор,
    // значки наборов и вкладки Stickers/GIF при следующем открытии всё
    // равно перезапрашиваются; сетка обычных эмодзи — это текст, она
    // остаётся (её постройка дорогая, а памяти почти не стоит).
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
  // Наборы кастомных эмодзи — и для реакции, и для композера. Спрашиваются
  // при каждом открытии: что установлено у аккаунта, могло измениться.
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
    // are a click away in the strip, not in front of them. Сами наборы
    // подтягивает toggle().
    showSet(null);
  }).catch(console.error);
}
