// The session on the server: where the server is and how to reach it.
//
// The page lives in two places:
// - in the fptg window — from the window's files (https://fptg.example/),
//   and the server — at the address from ?server=https://address:port;
// - in an ordinary browser — from the server itself, it is location.origin.
//
// Sign-in is by login and password (connect.html); its result is the
// session's refresh token. In the window it arrives in the address fragment
// (#r=, in the fragment it goes into no request) and is erased from there
// at once; in a browser it lies in localStorage. With it the server issues
// JWTs (POST /api/refresh): access — for an hour, it opens the WebSocket
// and uploads go with it; media — for /media/ addresses, without expiry,
// while the session lives.
//
// The session ended (sign-out, the server forgot it) — signedOut: in the
// window — to the shell (it shows the sign-in window), in a browser — to connect.html.

const params = new URLSearchParams(location.search);
const shell = window.chrome?.webview ?? null;
const SERVER_KEY = 'fptg.server';

// The server address — from ?server= (that is how the window opens the
// app), and it is remembered in the tab too: pages of the same origin
// without the parameter (the transport check, "back to the app") go there too.
function pickServer() {
  let base = params.get('server') || '';
  try {
    if (base) sessionStorage.setItem(SERVER_KEY, base);
    else base = sessionStorage.getItem(SERVER_KEY) || '';
  } catch { /* storage unavailable — only the parameter */ }
  return (base || location.origin).replace(/\/+$/, '');
}
export const serverBase = pickServer();

const REFRESH_KEY = 'fptg.refresh';
// The margin before access expires: renew in advance.
const RENEW_MARGIN_MS = 60000;

function store() {
  try {
    return shell ? sessionStorage : localStorage;
  } catch {
    return null;
  }
}

let refresh = '';
{
  const hash = new URLSearchParams(location.hash.slice(1));
  if (hash.get('r')) {
    refresh = hash.get('r');
    history.replaceState(null, '', location.pathname + location.search);
    // In the window — until the page reloads (F5), no longer: the window keeps it.
    try { store()?.setItem(REFRESH_KEY, refresh); } catch { /* unavailable — no harm */ }
  } else {
    try { refresh = store()?.getItem(REFRESH_KEY) || ''; } catch { refresh = ''; }
  }
}

let tokens = null;      // { access, media, user, expiresAt }
let renewing = null;

export const currentUser = () => tokens?.user ?? '';
export const mediaToken = () => tokens?.media ?? '';

function forget() {
  refresh = '';
  tokens = null;
  try { store()?.removeItem(REFRESH_KEY); } catch { /* nothing to erase */ }
}

/** The session ended: the shell gets the sign-in window, a browser — connect.html. */
export function signedOut(error = '') {
  forget();
  if (shell) {
    shell.postMessage(JSON.stringify({ t: 'signedOut', error }));
  } else {
    location.href = `connect.html?error=${encodeURIComponent(error)}`;
  }
}

/** Sign out: the server ends the session (and all its tokens), then — as signedOut. */
export async function signOut() {
  const r = refresh;
  if (r) {
    try {
      await fetch(`${serverBase}/api/logout`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh: r }),
      });
    } catch { /* the server is unreachable — the session on it will end by itself */ }
  }
  signedOut('');
}

async function doRenew() {
  if (!refresh) {
    signedOut('');
    throw Object.assign(new Error('signed out'), { signedOut: true });
  }
  let res;
  try {
    res = await fetch(`${serverBase}/api/refresh`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh }),
    });
  } catch {
    throw Object.assign(new Error('The server is unreachable'), { network: true });
  }
  if (res.status === 401) {
    const body = await res.json().catch(() => ({}));
    signedOut(body.error || 'The session has ended. Sign in again.');
    throw Object.assign(new Error('signed out'), { signedOut: true });
  }
  if (!res.ok) throw Object.assign(new Error(`The server answered ${res.status}`), { network: true });
  const t = await res.json();
  // The expiry — by our own clock: the server's clock may run differently.
  tokens = { access: t.access, media: t.media, user: t.user, expiresAt: Date.now() + t.ttl * 1000 };
}

/** The valid access token (renews it if it is time). */
export async function accessToken() {
  if (tokens && tokens.expiresAt - Date.now() > RENEW_MARGIN_MS) return tokens.access;
  if (!renewing) renewing = doRenew().finally(() => { renewing = null; });
  await renewing;
  return tokens.access;
}

/** The server refused a token we considered alive: take a new one on the
 *  next accessToken (and if there is no session — signedOut). */
export function dropAccess() {
  tokens = null;
}

/**
 * The server's file addresses in an answer — made full and with the media
 * token. The server writes them relative ("/media/123"): the page may be
 * not from its address, and cookies do not travel between addresses. One
 * place for the whole protocol — before parsing JSON, not in every consumer.
 */
export function absoluteMedia(text) {
  const t = encodeURIComponent(mediaToken());
  return text.replace(/"\/media\/(\d+)"/g, `"${serverBase}/media/$1?t=${t}"`);
}

/** The file upload address (POST /upload) with the access token. */
export async function uploadUrl(name) {
  const t = encodeURIComponent(await accessToken());
  return `${serverBase}/upload?name=${encodeURIComponent(name)}&t=${t}`;
}

/** The WebSocket address with the access token. */
export async function socketUrl() {
  const t = encodeURIComponent(await accessToken());
  return `${serverBase.replace(/^http/, 'ws')}/ws?t=${t}`;
}
