import { emit } from './bus.js';
import { socketUrl, absoluteMedia, dropAccess, signedOut } from './session.js';

// The server closed the socket: the session was ended (sign-out, the user
// removed, "sign out everyone" in the server window) — localserver, LOCAL_SERVER_WS_CLOSE_SESSION_ENDED.
const CLOSE_SESSION_ENDED = 4001;

// The socket, and the request/response discipline on top of it.
//
// The server speaks the protocol described in webapi.pas: a command
// carries an id and comes back with the same id, while anything without
// an id is an unsolicited event. Matching on the id is what allows
// several commands to be in flight at once without their answers
// getting crossed.
//
// The socket's address and token come from the session (core/session.js):
// the server may be elsewhere than the page, and lets in only with a valid JWT.

const RETRY_STEP_MS = 500;
const RETRY_MAX_STEPS = 6;
const CALL_TIMEOUT_MS = 15000;
// A command given while the socket is down waits this long for it to come
// back rather than failing at once: on a phone the file picker sends the
// page to the background, the system drops the socket, and the Send that
// follows lands in the middle of the reconnect.
const CALL_OPEN_WAIT_MS = 10000;

let socket = null;
let nextId = 1;
let retries = 0;
let retryTimer = 0;
// socketUrl() is on its way: a second connect() must not open a second socket.
let starting = false;
// The session ended (CLOSE_SESSION_ENDED): nothing reconnects any more.
let stopped = false;
const pending = new Map();
// Commands waiting for the socket to open (call while it is down).
const openWaiters = new Set();

export const state = { status: 'connecting' };

function setStatus(status) {
  state.status = status;
  emit('net:status', status);
}

function retryLater() {
  retries = Math.min(retries + 1, RETRY_MAX_STEPS);
  clearTimeout(retryTimer);
  retryTimer = setTimeout(() => {
    retryTimer = 0;
    connect();
  }, RETRY_STEP_MS * retries);
}

export function connect() {
  if (starting || socket?.readyState === WebSocket.CONNECTING
      || socket?.readyState === WebSocket.OPEN) return;
  starting = true;
  stopped = false;
  setStatus('connecting');
  socketUrl().then((url) => {
    starting = false;
    open(url);
  }, (error) => {
    starting = false;
    // The session ended — next is the sign-in window, there is nowhere to reconnect.
    if (error?.signedOut) return;
    setStatus('closed');
    retryLater();
  });
}

// The page is back on screen (a phone: after the file picker, another app,
// a locked screen) or the network is back: a dropped socket reconnects now,
// not when the back-off timer gets round to it. Only once there has been a
// socket — before the first connect() there is no session to resume.
function wake() {
  if (!socket || stopped) return;
  if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) return;
  clearTimeout(retryTimer);
  retryTimer = 0;
  retries = 0;
  connect();
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') wake();
});
window.addEventListener('online', wake);

function open(url) {
  let opened = false;
  socket = new WebSocket(url);

  socket.addEventListener('open', () => {
    opened = true;
    retries = 0;
    setStatus('open');
    for (const go of [...openWaiters]) go();
  });

  socket.addEventListener('message', (event) => {
    let message;
    try {
      message = JSON.parse(absoluteMedia(event.data));
    } catch {
      return;                       // not ours; ignore rather than throw
    }
    if (message.id && pending.has(message.id)) {
      const entry = pending.get(message.id);
      pending.delete(message.id);
      clearTimeout(entry.timer);
      message.ok ? entry.resolve(message.result)
                 : entry.reject(new Error(message.error || 'command failed'));
      return;
    }
    if (message.event) emit(`srv:${message.event}`, message.data);
    else if (message.type) emit(`srv:${message.type}`, message);
  });

  socket.addEventListener('close', (event) => {
    setStatus('closed');
    if (event.code === CLOSE_SESSION_ENDED) {
      for (const entry of pending.values()) {
        clearTimeout(entry.timer);
        entry.reject(new Error('signed out'));
      }
      pending.clear();
      stopped = true;
      // What is loaded on the page is no longer ours: to sign-in, without reconnecting.
      signedOut('You were signed out on the server.');
      return;
    }
    // Every waiting caller has to be told, or a promise created before
    // the drop never settles and whatever awaited it hangs for good.
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error('connection lost'));
    }
    pending.clear();
    // It did not open at all — perhaps the server did not accept the token
    // (the session ended, the key changed): next time — a new one.
    if (!opened) dropAccess();
    retryLater();
  });

  socket.addEventListener('error', () => setStatus('closed'));
}

export function call(cmd, args = {}) {
  if (socket?.readyState === WebSocket.OPEN) return send(cmd, args);
  // Never connected, or signed out: nothing to wait for.
  if (!socket || stopped) return Promise.reject(new Error('not connected'));
  wake();
  return whenOpen().then(() => send(cmd, args));
}

/** Resolves when the socket opens; fails after CALL_OPEN_WAIT_MS. */
function whenOpen() {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      openWaiters.delete(go);
      reject(new Error('not connected'));
    }, CALL_OPEN_WAIT_MS);
    function go() {
      clearTimeout(timer);
      openWaiters.delete(go);
      resolve();
    }
    openWaiters.add(go);
  });
}

function send(cmd, args) {
  return new Promise((resolve, reject) => {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      reject(new Error('not connected'));
      return;
    }
    const id = nextId++;
    // A command that never comes back must fail rather than linger:
    // without this a single dropped answer leaks an entry and its
    // caller waits forever.
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`"${cmd}" timed out`));
    }, CALL_TIMEOUT_MS);

    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, cmd, args }));
  });
}
