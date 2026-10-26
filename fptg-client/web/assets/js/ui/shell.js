import { on, emit } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { signOut, signedOut } from '../core/session.js';

// The page's link with the shell — the fptg window (fptg-client).
//
// The window and the server are different programs, and the window may be
// on another machine than the server. So everything the window needs from
// the server goes through this page: it is already connected to the
// server over the WebSocket, and talks to the window through chrome.webview
// (WebView2; on another platform — its own shell with the same protocol).
//
// Page -> window (postShell):
//   config {closeToTray, notify}  the settings the window carries out;
//   notify {chatId, title, text, photo, thumb}  a desktop card (the photo
//     is a data: URL: the files are on the server, not with the window);
//   notifySample                  a sample of the cards (settings);
//   notifyClear {chatId}          the chat is read: its card or notification
//     goes (here, in another client or on the phone - the unread count);
//   miniapp {url, title, bot, launch, buttonText, theme}  open a mini app
//     (the webapp.open answer);
//   miniappResp {id, ok, result, error}  the server's answer to miniappReq;
//   callpopup — the call pop-up (ui/call.js);
//   frame {caption, text, border, card, dim, dark}  the window frame and
//     the message cards in the theme's colours, '#rrggbb' (ui/theme.js; the
//     window — winframe.pas, desknotify.pas).
// Window -> page:
//   signOut             tray → Sign out;
//   certificate {origin, fingerprint, changed}  the server certificate is
//     not the trusted one (in the app — back to the sign-in window);
//   openChat {chatId}   a click on a desktop card;
//   openLink {url}      a t.me link from a mini app;
//   miniappReq {id, cmd, args}  a mini app's request to the server;
//   call — a press on the call pop-up (ui/call.js);
//   downloadFailed      a file from a message did not download (webui.ViewDownloadDone;
//     the window opens a successful one with an external app itself).
//
// In an ordinary browser there is no shell: everything here is silent, and
// a mini app opens as a tab.

const host = window.chrome?.webview ?? null;

// Only these commands may a mini app window ask of the server.
const MINIAPP_COMMANDS = new Set(['webapp.close', 'webapp.custom', 'webapp.allowWrite', 'webapp.sendData']);

let hooks = {};
let notifyOn = false;

export const inShell = () => host !== null;

export function postShell(msg) {
  host?.postMessage(JSON.stringify(msg));
}

/** The settings the window carries out: closing to the tray and the cards. */
export function shellSettings(data) {
  if (!host || !data) return;
  notifyOn = !!data.notify?.enabled;
  postShell({ t: 'config', closeToTray: !!data.closeToTray, notify: data.notify ?? {} });
}

/** The webapp.open answer: in our window — a mini app window, otherwise a tab. */
export function openMiniApp(app) {
  if (!app?.url) return;
  if (host) postShell({ t: 'miniapp', ...app });
  else window.open(app.url, '_blank', 'noopener');
}

/** A file from the server (/media/…, the cookie authorizes) — into a data: URL for the window. */
async function asDataUrl(url) {
  if (!url) return '';
  try {
    const res = await fetch(url);
    if (!res.ok) return '';
    const blob = await res.blob();
    return await new Promise((resolve) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result));
      reader.onerror = () => resolve('');
      reader.readAsDataURL(blob);
    });
  } catch {
    return '';
  }
}

// Chats with a card or notification out: it goes once the chat is read.
const noticed = new Set();

function readChats(chats) {
  for (const chat of chats ?? []) {
    if (!noticed.has(chat.id) || chat.unread > 0) continue;
    noticed.delete(chat.id);
    postShell({ t: 'notifyClear', chatId: chat.id });
  }
}

async function arrived(data) {
  if (!host || !notifyOn || !data) return;
  // The window is in front of the eyes and this chat is open in it — nothing to report.
  if (!document.hidden && document.hasFocus() && data.chatId === store.activeChatId) return;
  noticed.add(data.chatId);
  postShell({
    t: 'notify',
    chatId: data.chatId,
    title: data.title || '',
    text: data.text || '',
    photo: await asDataUrl(data.avatar),
    thumb: data.thumb || '',
  });
}

async function miniappRequest(m) {
  if (!MINIAPP_COMMANDS.has(m.cmd)) return;
  let reply;
  try {
    reply = { ok: true, result: await hooks.call(m.cmd, m.args ?? {}) };
  } catch (error) {
    reply = { ok: false, error: error?.message || String(error) };
  }
  if (m.id) postShell({ t: 'miniappResp', id: m.id, ...reply });
}

function onHostMessage(m) {
  if (!m?.t) return;
  if (m.t === 'signOut') signOut();
  else if (m.t === 'certificate') {
    signedOut(m.changed
      ? 'The server certificate has changed. Check its fingerprint before signing in again.'
      : 'The server certificate is not trusted. Sign in to check its fingerprint.');
  } else if (m.t === 'openChat' && m.chatId) setActiveChat(m.chatId);
  else if (m.t === 'openLink') hooks.openLink?.(m.url);
  else if (m.t === 'downloadFailed') emit('ui:error', 'Could not download the file');
  else if (m.t === 'miniappReq') miniappRequest(m).catch(() => {});
}

/** hooks: { call(cmd, args), openLink(url), report(err) } */
export function mountShell(options) {
  hooks = options ?? {};
  if (!host) return;
  host.addEventListener('message', (event) => onHostMessage(event.data));
  on('srv:arrival', (data) => { arrived(data).catch(() => {}); });
  on('store:chats', readChats);
  on('srv:settings', shellSettings);
  // The settings — on every (re)connection: the window may have connected to
  // another server, or they changed while there was no connection.
  on('net:status', (status) => {
    if (status !== 'open') return;
    hooks.call('settings.get').then(shellSettings).catch(() => {});
  });
}
