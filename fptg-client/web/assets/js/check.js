import { el, qs, clear } from './core/dom.js';
import { socketUrl } from './core/session.js';

// Standalone on purpose: this page has to stay usable when the app
// modules are the thing that is broken. It therefore talks to the
// socket directly instead of going through core/net.js. The server address
// and token come from the session (core/session.js): the page may be not
// from the server, and the socket lets in only with a valid JWT.

const log = qs('#log');
const conn = qs('#conn');
let socket = null;
let retries = 0;
let sentAt = 0;
let count = 0;
let bytes = 0;

function line(kind, text) {
  const stick = log.scrollTop + log.clientHeight > log.scrollHeight - 30;
  log.append(el('div', { class: 'check__line' },
    el('span', { class: 'check__ts', textContent: new Date().toTimeString().slice(0, 8) }),
    el('span', { class: `check__${kind}`, textContent: text }),
  ));
  while (log.childElementCount > 500) log.removeChild(log.firstChild);
  if (stick) log.scrollTop = log.scrollHeight;
}

function short(text) {
  return text.length > 160 ? `${text.slice(0, 160)} ...(${text.length} bytes)` : text;
}

function setStatus(status, label) {
  conn.className = `conn is-${status}`;
  clear(conn).append(
    el('span', { class: 'conn__dot' }),
    el('span', { class: 'conn__label', textContent: label }),
  );
  for (const id of ['send', 'big', 'burst']) qs(`#${id}`).disabled = status !== 'open';
}

async function connect() {
  setStatus('connecting', 'connecting...');
  let url;
  try {
    url = await socketUrl();
  } catch (error) {
    // No session — session.js has sent to sign-in already; otherwise — a retry.
    if (error?.signedOut) return;
    line('ts', `no token: ${error?.message || error}`);
    retries = Math.min(retries + 1, 6);
    setTimeout(connect, 500 * retries);
    return;
  }
  line('ts', `connecting to ${url.replace(/t=[^&]*/, 't=***')}`);
  socket = new WebSocket(url);

  socket.addEventListener('open', () => { retries = 0; setStatus('open', 'open'); });

  socket.addEventListener('message', (event) => {
    count += 1;
    bytes += event.data.length;
    qs('#nin').textContent = count;
    qs('#nbytes').textContent = bytes.toLocaleString();
    if (sentAt) {
      qs('#rtt').textContent = (performance.now() - sentAt).toFixed(1);
      sentAt = 0;
    }
    line('in', `< ${short(String(event.data))}`);
  });

  socket.addEventListener('close', (event) => {
    setStatus('closed', `closed (${event.code})`);
    retries = Math.min(retries + 1, 6);
    setTimeout(connect, 500 * retries);
  });
}

function send(text) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  sentAt = performance.now();
  socket.send(text);
  line('out', `> ${short(text)}`);
}

qs('#send').addEventListener('click', () => {
  const field = qs('#msg');
  if (field.value) { send(field.value); field.value = ''; }
});
qs('#msg').addEventListener('keydown', (e) => { if (e.key === 'Enter') qs('#send').click(); });

// 200 KB crosses 65535, so the browser must use the 64-bit length form -
// the single most commonly botched part of RFC 6455 framing, and one
// that works fine right up until a real history page is sent.
qs('#big').addEventListener('click', () => send('X'.repeat(200 * 1024)));

qs('#burst').addEventListener('click', () => {
  for (let i = 0; i < 50; i += 1) send(`burst ${i}`);
});

qs('#clear').addEventListener('click', () => {
  clear(log);
  count = 0; bytes = 0;
  qs('#nin').textContent = '0';
  qs('#nbytes').textContent = '0';
});

connect();
