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

let socket = null;
let nextId = 1;
let retries = 0;
const pending = new Map();

export const state = { status: 'connecting' };

function setStatus(status) {
  state.status = status;
  emit('net:status', status);
}

function retryLater() {
  retries = Math.min(retries + 1, RETRY_MAX_STEPS);
  setTimeout(connect, RETRY_STEP_MS * retries);
}

export function connect() {
  setStatus('connecting');
  socketUrl().then(open, (error) => {
    // The session ended — next is the sign-in window, there is nowhere to reconnect.
    if (error?.signedOut) return;
    setStatus('closed');
    retryLater();
  });
}

function open(url) {
  let opened = false;
  socket = new WebSocket(url);

  socket.addEventListener('open', () => {
    opened = true;
    retries = 0;
    setStatus('open');
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
