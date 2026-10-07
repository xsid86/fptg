import { emit } from './bus.js';

// The socket, and the request/response discipline on top of it.
//
// The server speaks the protocol described in webapi.pas: a command
// carries an id and comes back with the same id, while anything without
// an id is an unsolicited event. Matching on the id is what allows
// several commands to be in flight at once without their answers
// getting crossed.

const token = new URLSearchParams(location.search).get('t') ?? '';
const url = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws?t=${encodeURIComponent(token)}`;

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

export function connect() {
  setStatus('connecting');
  socket = new WebSocket(url);

  socket.addEventListener('open', () => {
    retries = 0;
    setStatus('open');
  });

  socket.addEventListener('message', (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
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

  socket.addEventListener('close', () => {
    setStatus('closed');
    // Every waiting caller has to be told, or a promise created before
    // the drop never settles and whatever awaited it hangs for good.
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error('connection lost'));
    }
    pending.clear();

    retries = Math.min(retries + 1, RETRY_MAX_STEPS);
    setTimeout(connect, RETRY_STEP_MS * retries);
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
