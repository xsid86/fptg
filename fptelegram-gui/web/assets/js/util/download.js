// Адрес файла с сервера (/media/…) для СОХРАНЕНИЯ, а не показа.
//
// Атрибут download у ссылки на чужой origin браузер не слушает: сервер —
// другой origin, чем страница окна (https://fptelegram.example/), и PDF
// по такой ссылке открывался прямо в окне, а дороги назад не было.
// Поэтому имя едет параметром save: сервер отдаёт файл вложением
// (Content-Disposition: attachment, localserver.ServeMedia), и это
// загрузка в любом браузере.
//
// open — ещё и открыть внешним приложением: в окне FPTelegram такую
// загрузку забирает оболочка (webui.ViewDownloadStart) и открывает
// готовый файл системой; в обычном браузере — просто загрузка.

// Без имени (фото, видео) — '*': сервер возьмёт имя файла на диске, с
// расширением.
export function downloadUrl(url, name, open = false) {
  const u = new URL(url, window.location.href);
  u.searchParams.set('save', name || '*');
  if (open) u.searchParams.set('open', '1');
  return u.href;
}
