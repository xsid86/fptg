import { qs, clear, el } from '../core/dom.js';
import { on } from '../core/bus.js';
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

function renderStatus(status) {
  conn.className = `conn is-${status}`;
  clear(conn).append(
    el('span', { class: 'conn__dot' }),
    el('span', { class: 'conn__label', textContent: LABEL[status] ?? status }),
  );
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
  on('net:status', renderStatus);
  on('store:chats', renderCounts);
  on('ui:error', showError);
  renderStatus('connecting');
  renderCounts();
}
