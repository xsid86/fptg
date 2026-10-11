import { on, emit } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { signOut, signedOut } from '../core/session.js';

// Связь страницы с оболочкой — окном FPTelegram (fptelegram-gui).
//
// Окно и сервер — разные программы, и окно может быть на другой машине,
// чем сервер. Поэтому всё, что окну нужно от сервера, идёт через эту
// страницу: она уже подключена к серверу по веб-сокету, а с окном
// говорит через chrome.webview (WebView2; на другой платформе — своя
// оболочка с тем же протоколом).
//
// Страница -> окно (postShell):
//   config {closeToTray, notify}  настройки, которые исполняет окно;
//   notify {chatId, title, text, photo, thumb}  карточка на рабочем
//     столе (фото — data: URL: файлы на сервере, не у окна);
//   notifySample                  образец карточек (настройки);
//   miniapp {url, title, bot, launch, buttonText, theme}  открыть
//     мини-приложение (ответ webapp.open);
//   miniappResp {id, ok, result, error}  ответ сервера на miniappReq;
//   callpopup — окошко звонка (ui/call.js);
//   frame {caption, text, border, dark}  цвета рамки окна по теме,
//     '#rrggbb' (ui/theme.js; окно — winframe.pas).
// Окно -> страница:
//   signOut             трей → Sign out;
//   certificate {origin, fingerprint, changed}  сертификат сервера не
//     тот, которому доверились (в приложении — назад к окну входа);
//   openChat {chatId}   клик по карточке на рабочем столе;
//   openLink {url}      ссылка t.me из мини-приложения;
//   miniappReq {id, cmd, args}  запрос мини-приложения к серверу;
//   call — нажатие на окошке звонка (ui/call.js);
//   downloadFailed      файл из сообщения не скачался (webui.ViewDownloadDone;
//     удачный окно само открывает внешним приложением).
//
// В обычном браузере оболочки нет: всё здесь молчит, а мини-приложение
// открывается вкладкой.

const host = window.chrome?.webview ?? null;

// Только эти команды окно мини-приложения может просить у сервера.
const MINIAPP_COMMANDS = new Set(['webapp.close', 'webapp.custom', 'webapp.allowWrite', 'webapp.sendData']);

let hooks = {};
let notifyOn = false;

export const inShell = () => host !== null;

export function postShell(msg) {
  host?.postMessage(JSON.stringify(msg));
}

/** Настройки, которые исполняет окно: закрытие в трей и карточки. */
export function shellSettings(data) {
  if (!host || !data) return;
  notifyOn = !!data.notify?.enabled;
  postShell({ t: 'config', closeToTray: !!data.closeToTray, notify: data.notify ?? {} });
}

/** Ответ webapp.open: в нашем окне — окно мини-приложения, иначе вкладка. */
export function openMiniApp(app) {
  if (!app?.url) return;
  if (host) postShell({ t: 'miniapp', ...app });
  else window.open(app.url, '_blank', 'noopener');
}

/** Файл с сервера (/media/…, cookie авторизует) — в data: URL для окна. */
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

async function arrived(data) {
  if (!host || !notifyOn || !data) return;
  // Окно перед глазами и этот чат в нём открыт — сообщать не о чем.
  if (!document.hidden && document.hasFocus() && data.chatId === store.activeChatId) return;
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
  on('srv:settings', shellSettings);
  // Настройки — при каждом (пере)подключении: окно могло подключиться к
  // другому серверу, или они поменялись, пока связи не было.
  on('net:status', (status) => {
    if (status !== 'open') return;
    hooks.call('settings.get').then(shellSettings).catch(() => {});
  });
}
