import { call } from '../core/net.js';
import { on } from '../core/bus.js';

// One's own action in the open chat — "typing", "sending a photo" — with
// the chat.typing command (webapi CmdChatTyping -> TDLib sendChatAction).
// The Telegram API terms (§1.3): a client does not suppress the typing
// indicator, so sending it is a duty, not a decoration. Incoming ones —
// ui/typing.js.
//
// On the other side an action goes out by itself after ~6 s, so while it
// lasts it is repeated every REPEAT_MS, not on every key. A cancel — only
// if something was sent: a needless chatActionCancel is a request too.
const REPEAT_MS = 5000;

let current = '';       // what went last: '' | typing | photo | video | document
let sentAt = 0;
let uploadTimer = 0;

function post(action) {
  // Nobody waits for the answer: a refusal (no right to write) is no news.
  call('chat.typing', { action }).catch(() => {});
}

/** The user is typing text: empty — the field became empty. */
export function noteTyping(empty) {
  if (empty) {
    stopAction();
    return;
  }
  if (uploadTimer) return;      // an upload matters more than "typing"
  const now = Date.now();
  if (current === 'typing' && now - sentAt < REPEAT_MS) return;
  current = 'typing';
  sentAt = now;
  post('typing');
}

/**
 * A file goes from the page to the server (ui/attach.js): kind — photo,
 * video or document. After that, while uploading to Telegram, TDLib itself
 * sends the action.
 */
export function startUpload(kind) {
  if (uploadTimer && current === kind) return;
  clearInterval(uploadTimer);
  current = kind;
  sentAt = Date.now();
  post(kind);
  uploadTimer = setInterval(() => {
    sentAt = Date.now();
    post(kind);
  }, REPEAT_MS);
}

/** Stop repeating the upload; the sent message cancels it by itself. */
export function endUpload() {
  clearInterval(uploadTimer);
  uploadTimer = 0;
  current = '';
}

/** Cancel what still hangs on the other side (clearing the field, cancelling an upload). */
export function stopAction() {
  const live = current && Date.now() - sentAt < REPEAT_MS + 1000;
  clearInterval(uploadTimer);
  uploadTimer = 0;
  current = '';
  if (live) post('cancel');
}

// The chat changed (exactly a change, not an update of the chat's row —
// that would come in the middle of an upload too): the model on the server
// already looks at another one, so the cancel would go to the wrong place.
// The old one goes out on the other side by itself.
on('store:active', () => endUpload());
