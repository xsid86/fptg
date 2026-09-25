import { qs, clear, el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { call } from '../core/net.js';
import { store } from '../core/store.js';

// Connection state and a couple of counters. Deliberately the only
// place that reports the socket: a status that appears in two places
// eventually disagrees with itself.

const LABEL = {
  connecting: 'connecting...',
  open: 'connected',
  closed: 'disconnected',
};

let conn = null;
let counts = null;
let presence = null;
// What the server last said. Never guessed from the click: the switch
// is remembered on disk and shared with the native window, so the
// answer is the only thing that knows.
let invisible = false;

function renderStatus(status) {
  conn.className = `conn is-${status}`;
  clear(conn).append(
    el('span', { class: 'conn__dot' }),
    el('span', { class: 'conn__label', textContent: LABEL[status] ?? status }),
  );
}

// Online or Invisible, the same switch the native window keeps in its
// status bar - and in the same corner, because that is where it has
// always been.
//
// Invisible is not decoration: while it is on, nothing this client
// reads is reported back (viewMessages is withheld in the model) and
// contacts are not shown an online presence. So it says which one is
// on in words, not only by colour.
function renderPresence() {
  presence.classList.toggle('is-invisible', invisible);
  presence.title = invisible
    ? 'Invisible: messages are not marked as read and contacts do not see you online'
    : 'Online: reading a chat marks its messages as read';
  clear(presence).append(
    el('span', { class: 'conn__dot' }),
    el('span', { textContent: invisible ? 'Invisible' : 'Online' }),
  );
}

async function loadPresence() {
  try {
    const answer = await call('presence.get');
    invisible = !!answer.invisible;
  } catch {
    return;                       // the connection will say so itself
  }
  renderPresence();
}

async function togglePresence() {
  presence.disabled = true;
  try {
    const answer = await call('presence.set', { invisible: !invisible });
    invisible = !!answer.invisible;
    renderPresence();
  } catch (error) {
    showError(error.message);
  } finally {
    presence.disabled = false;
  }
}

function renderCounts() {
  const total = store.chats.length;
  const unread = store.chats.reduce((sum, c) => sum + (c.unread || 0), 0);
  clear(counts).append(
    el('span', { class: 'status-bar__item u-tabular', textContent: `${total} chats` }),
    el('span', { class: 'status-bar__item u-tabular', textContent: `${unread} unread` }),
  );
}

let errorTimer = null;

function showError(message) {
  let slot = qs('.status-bar__error', conn.parentElement);
  if (!slot) {
    slot = el('span', { class: 'status-bar__error' });
    conn.after(slot);
  }
  slot.textContent = message;
  // Cleared after a while rather than left standing: a stale failure
  // next to a working connection reads as a current one.
  clearTimeout(errorTimer);
  errorTimer = setTimeout(() => { slot.textContent = ''; }, 6000);
}

export function mountStatusBar(node) {
  conn = qs('.conn', node);
  counts = qs('.status-bar__counts', node);
  presence = qs('.status-bar__presence', node);
  presence.addEventListener('click', togglePresence);
  on('net:status', (status) => {
    renderStatus(status);
    // Asked again on every connect, not once at start-up: another page
    // - or the native window - may have flipped it while this one was
    // away, and the server is the one that knows.
    if (status === 'open') loadPresence();
  });
  on('srv:presence', (data) => {
    invisible = !!data?.invisible;
    renderPresence();
  });
  on('store:chats', renderCounts);
  on('ui:error', showError);
  renderStatus('connecting');
  renderPresence();
  renderCounts();
}
