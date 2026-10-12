// Сеанс на сервере: где сервер и чем к нему ходить.
//
// Страница бывает в двух местах:
// - в окне fptg — из файлов окна (https://fptg.example/),
//   а сервер — по адресу из ?server=https://адрес:порт;
// - в обычном браузере — с самого сервера, он и есть location.origin.
//
// Вход — логином и паролем (connect.html); его итог — refresh-токен
// сеанса. В окне он приходит во фрагменте адреса (#r=, во фрагменте он
// не уходит ни в один запрос) и сразу оттуда стирается; в браузере
// лежит в localStorage. По нему сервер выдаёт JWT (POST /api/refresh):
// access — на час, им открывается веб-сокет и идут загрузки; media —
// для адресов /media/, без срока, пока жив сеанс.
//
// Сеанс кончился (выход, сервер его забыл) — signedOut: в окне — оболочке
// (она покажет окно входа), в браузере — на connect.html.

const params = new URLSearchParams(location.search);
const shell = window.chrome?.webview ?? null;
const SERVER_KEY = 'fptg.server';

// Адрес сервера — из ?server= (так окно открывает приложение), и он же
// запоминается во вкладке: страницы того же происхождения без параметра
// (проверка транспорта, «назад в приложение») ходят туда же.
function pickServer() {
  let base = params.get('server') || '';
  try {
    if (base) sessionStorage.setItem(SERVER_KEY, base);
    else base = sessionStorage.getItem(SERVER_KEY) || '';
  } catch { /* хранилище недоступно — только параметр */ }
  return (base || location.origin).replace(/\/+$/, '');
}
export const serverBase = pickServer();

const REFRESH_KEY = 'fptg.refresh';
// Запас до конца срока access: продлевать заранее.
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
    // В окне — до перезагрузки страницы (F5), не дольше: хранит его окно.
    try { store()?.setItem(REFRESH_KEY, refresh); } catch { /* недоступно — не страшно */ }
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
  try { store()?.removeItem(REFRESH_KEY); } catch { /* нечего стирать */ }
}

/** Сеанс кончился: оболочке — окно входа, браузеру — connect.html. */
export function signedOut(error = '') {
  forget();
  if (shell) {
    shell.postMessage(JSON.stringify({ t: 'signedOut', error }));
  } else {
    location.href = `connect.html?error=${encodeURIComponent(error)}`;
  }
}

/** Выйти: сервер гасит сеанс (и все его токены), дальше — как signedOut. */
export async function signOut() {
  const r = refresh;
  if (r) {
    try {
      await fetch(`${serverBase}/api/logout`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh: r }),
      });
    } catch { /* сервер недоступен — сеанс на нём погаснет сам */ }
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
  // Срок — по своим часам: часы сервера могут идти иначе.
  tokens = { access: t.access, media: t.media, user: t.user, expiresAt: Date.now() + t.ttl * 1000 };
}

/** Действующий access-токен (продлевает, если пора). */
export async function accessToken() {
  if (tokens && tokens.expiresAt - Date.now() > RENEW_MARGIN_MS) return tokens.access;
  if (!renewing) renewing = doRenew().finally(() => { renewing = null; });
  await renewing;
  return tokens.access;
}

/** Сервер отказал в токене, который мы считали живым: при следующем
 *  accessToken взять новый (а если сеанса нет — signedOut). */
export function dropAccess() {
  tokens = null;
}

/**
 * Адреса файлов сервера в ответе — полными и с медиа-токеном. Сервер
 * пишет их относительными ("/media/123"): страница может быть не с его
 * адреса, а cookie между адресами не ходят. Одно место на весь протокол
 * — до разбора JSON, а не в каждом потребителе.
 */
export function absoluteMedia(text) {
  const t = encodeURIComponent(mediaToken());
  return text.replace(/"\/media\/(\d+)"/g, `"${serverBase}/media/$1?t=${t}"`);
}

/** Адрес загрузки файла (POST /upload) с access-токеном. */
export async function uploadUrl(name) {
  const t = encodeURIComponent(await accessToken());
  return `${serverBase}/upload?name=${encodeURIComponent(name)}&t=${t}`;
}

/** Адрес веб-сокета с access-токеном. */
export async function socketUrl() {
  const t = encodeURIComponent(await accessToken());
  return `${serverBase.replace(/^http/, 'ws')}/ws?t=${t}`;
}
