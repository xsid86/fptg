// Окно ввода подключения (connect.html). Обычный скрипт, не модуль:
// страницу оболочка открывает по file://, а там модули не грузятся.
//
// Что было сохранено и почему не подключилось — в адресе страницы
// (?host=&port=&token=&error=). Нажатие — оболочке
// {t:'connect', host, port, token}; она проверяет сервер и либо уходит
// на его страницу, либо отвечает {t:'connectState', busy, error}.
(function () {
  'use strict';

  var host = window.chrome && window.chrome.webview ? window.chrome.webview : null;
  var q = new URLSearchParams(location.search);
  var $ = function (id) { return document.getElementById(id); };

  function showError(text) {
    var line = $('error');
    line.textContent = text || '';
    line.hidden = !text;
  }

  function setBusy(busy) {
    $('submit').disabled = busy;
    $('submit').textContent = busy ? 'Connecting…' : 'Connect';
  }

  // Вставили ссылку веб-интерфейса целиком: http://адрес:порт/?t=токен.
  function takeLink(value) {
    var url;
    try {
      url = new URL(value.trim());
    } catch (e) {
      return false;
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
    $('host').value = url.hostname.replace(/^\[|\]$/g, '');
    $('port').value = url.port || (url.protocol === 'https:' ? '443' : '80');
    var t = url.searchParams.get('t');
    if (t) $('token').value = t;
    return true;
  }

  function submit(event) {
    event.preventDefault();
    var hostName = $('host').value.trim();
    var port = parseInt($('port').value.trim(), 10);
    var token = $('token').value.trim();
    if (!hostName) { showError('Enter the server address.'); return; }
    if (!(port > 0 && port <= 65535)) { showError('The port is a number from 1 to 65535.'); return; }
    if (!token) { showError('Enter the token.'); return; }
    showError('');
    if (!host) { showError('This page only works inside the program window.'); return; }
    setBusy(true);
    host.postMessage(JSON.stringify({ t: 'connect', host: hostName, port: port, token: token }));
  }

  function onHostMessage(event) {
    var m = event.data;
    if (!m || m.t !== 'connectState') return;
    setBusy(!!m.busy);
    showError(m.error || '');
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('host').value = q.get('host') || '';
    $('port').value = q.get('port') || '';
    $('token').value = q.get('token') || '';
    showError(q.get('error') || '');
    // Оболочка уже проверяет сохранённое подключение.
    if (q.get('busy') === '1') setBusy(true);
    $('host').addEventListener('paste', function (event) {
      var text = event.clipboardData ? event.clipboardData.getData('text') : '';
      if (/^https?:\/\//i.test(text.trim()) && takeLink(text)) event.preventDefault();
    });
    $('form').addEventListener('submit', submit);
    if (host) host.addEventListener('message', onHostMessage);
    if ($('host').value) $('token').focus();
  });
})();
