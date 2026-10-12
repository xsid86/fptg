import { call } from '../core/net.js';
import { on } from '../core/bus.js';

// Своё действие в открытом чате — «печатает», «отправляет фото» —
// командой chat.typing (webapi CmdChatTyping -> sendChatAction TDLib).
// Условия Telegram API (§1.3): клиент не глушит индикатор набора, так
// что слать его — обязанность, а не украшение. Входящие — ui/typing.js.
//
// У собеседника действие гаснет само через ~6 с, поэтому, пока оно
// идёт, его повторяют раз в REPEAT_MS, не на каждую клавишу. Отмена —
// только если что-то было послано: лишний chatActionCancel тоже запрос.
const REPEAT_MS = 5000;

let current = '';       // что последним ушло: '' | typing | photo | video | document
let sentAt = 0;
let uploadTimer = 0;

function post(action) {
  // Ответа никто не ждёт: отказ (нет права писать) — не новость.
  call('chat.typing', { action }).catch(() => {});
}

/** Пользователь набирает текст: empty — поле стало пустым. */
export function noteTyping(empty) {
  if (empty) {
    stopAction();
    return;
  }
  if (uploadTimer) return;      // загрузка важнее «печатает»
  const now = Date.now();
  if (current === 'typing' && now - sentAt < REPEAT_MS) return;
  current = 'typing';
  sentAt = now;
  post('typing');
}

/**
 * Файл уходит со страницы на сервер (ui/attach.js): kind — photo,
 * video или document. Дальше, на загрузке в Telegram, действие шлёт
 * сама TDLib.
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

/** Повтор загрузки — прекратить; отправленное сообщение гасит его само. */
export function endUpload() {
  clearInterval(uploadTimer);
  uploadTimer = 0;
  current = '';
}

/** Отменить то, что ещё висит у собеседника (очистка поля, отмена загрузки). */
export function stopAction() {
  const live = current && Date.now() - sentAt < REPEAT_MS + 1000;
  clearInterval(uploadTimer);
  uploadTimer = 0;
  current = '';
  if (live) post('cancel');
}

// Чат сменился (именно смена, не обновление строки чата — то пришло бы
// и посреди загрузки): модель на сервере уже смотрит в другой, так что
// отмена ушла бы не туда. Старое погаснет у собеседника само.
on('store:active', () => endUpload());
