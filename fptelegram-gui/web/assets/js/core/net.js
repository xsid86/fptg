import { emit } from './bus.js';
import { socketUrl, absoluteMedia, dropAccess } from './session.js';

// The socket, and the request/response discipline on top of it.
//
// The server speaks the protocol described in webapi.pas: a command
// carries an id and comes back with the same id, while anything without
// an id is an unsolicited event. Matching on the id is what allows
// several commands to be in flight at once without their answers
// getting crossed.
//
// Адрес и токен сокета — от сеанса (core/session.js): сервер может быть
// не там, откуда страница, и пускает только с действующим JWT.

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
    // Сеанс кончился — дальше окно входа, переподключаться некуда.
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

  socket.addEventListener('close', () => {
    setStatus('closed');
    // Every waiting caller has to be told, or a promise created before
    // the drop never settles and whatever awaited it hangs for good.
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error('connection lost'));
    }
    pending.clear();
    // Не открылся вовсе — возможно, сервер не принял токен (сеанс
    // погашен, ключ сменён): в следующий раз — новый.
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
