// Signing in to the server (connect.html): login and password -> the
// session's refresh token (POST /api/login, srvauth.pas).
//
// In the fptg window the page is from the window's files, the server's
// address and port are entered; a successful sign-in goes to the shell
// {t:'session', host, port, user, refresh} — it remembers it in conf.dat
// and opens the app. The window lets the server's self-signed certificate
// through only if the person trusted it: an unknown one it refuses and
// sends here {t:'certificate', origin, fingerprint, changed}; "trust" —
// back {t:'trustCert', origin, fingerprint}, and the sign-in is repeated.
//
// In an ordinary browser the page is from the server itself: the address is
// not asked, the refresh token goes into localStorage (core/session.js reads it there).
//
// A plain script, not a module — as it was: the page depends on nothing.
(function () {
  'use strict';

  var shell = window.chrome && window.chrome.webview ? window.chrome.webview : null;
  var q = new URLSearchParams(location.search);
  var $ = function (id) { return document.getElementById(id); };
  var REFRESH_KEY = 'fptg.refresh';
  // How long to wait for news about the certificate from the window before
  // considering the server unreachable: the fetch refusal and the window's
  // message arrive in any order.
  var CERT_WAIT_MS = 500;

  var lastCert = null;      // {origin, fingerprint, changed}

  function showError(text) {
    $('error').textContent = text || '';
    $('error').hidden = !text;
  }

  function setBusy(busy) {
    $('submit').disabled = busy;
    $('submit').textContent = busy ? 'Signing in…' : 'Sign in';
  }

  function serverOrigin() {
    if (!shell) return location.origin;
    var h = $('host').value.trim();
    if (h.indexOf(':') >= 0 && h.charAt(0) !== '[') h = '[' + h + ']';
    return 'https://' + h + ':' + parseInt($('port').value.trim(), 10);
  }

  function sleep(ms) {
    return new Promise(function (r) { setTimeout(r, ms); });
  }

  function showCert(cert) {
    $('certWarn').textContent = cert.changed
      ? 'WARNING: this server’s certificate has CHANGED since you last trusted it. '
        + 'Someone may be impersonating the server.'
      : 'This server uses its own (self-signed) certificate.';
    // A space after every eight bytes: 95 characters without spaces do not
    // wrap and would stick out of the card.
    $('certPrint').textContent = cert.fingerprint.replace(/((?:[0-9A-F]{2}:){8})/g, '$1 ');
    $('cert').hidden = false;
    $('form').hidden = true;
  }

  function hideCert() {
    $('cert').hidden = true;
    $('form').hidden = false;
  }

  async function signIn() {
    var user = $('user').value.trim();
    var password = $('password').value;
    if (shell) {
      if (!$('host').value.trim()) { showError('Enter the server address.'); return; }
      var port = parseInt($('port').value.trim(), 10);
      if (!(port > 0 && port <= 65535)) { showError('The port is a number from 1 to 65535.'); return; }
    }
    if (!user || !password) { showError('Enter the user name and password.'); return; }
    showError('');
    setBusy(true);
    lastCert = null;
    var origin = serverOrigin();
    var res;
    try {
      res = await fetch(origin + '/api/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ user: user, password: password,
          device: shell ? 'fptg window' : 'Browser' }),
      });
    } catch (e) {
      await sleep(CERT_WAIT_MS);
      setBusy(false);
      if (lastCert && lastCert.origin === origin.toLowerCase()) {
        showCert(lastCert);
      } else {
        showError('Could not reach the server at ' + origin + '.');
      }
      return;
    }
    var body = {};
    try { body = await res.json(); } catch (e) { body = {}; }
    if (!res.ok || !body.refresh) {
      setBusy(false);
      showError(body.error || ('The server answered ' + res.status + '.'));
      return;
    }
    if (shell) {
      shell.postMessage(JSON.stringify({ t: 'session', host: $('host').value.trim(),
        port: parseInt($('port').value.trim(), 10), user: user, refresh: body.refresh }));
    } else {
      try { localStorage.setItem(REFRESH_KEY, body.refresh); } catch (e) { /* without it — sign in every time */ }
      location.href = 'index.html';
    }
  }

  function onHostMessage(event) {
    var m = event.data;
    if (m && m.t === 'certificate') lastCert = m;
  }

  document.addEventListener('DOMContentLoaded', function () {
    if (!shell) {
      $('hostField').hidden = true;
      $('portField').hidden = true;
      $('note').textContent = 'The login and password are set on the server: User in its window, or --set-user.';
    }
    $('host').value = q.get('host') || '';
    $('port').value = q.get('port') || '';
    $('user').value = q.get('user') || '';
    showError(q.get('error') || '');
    $('form').addEventListener('submit', function (event) {
      event.preventDefault();
      signIn();
    });
    $('certForm').addEventListener('submit', function (event) {
      event.preventDefault();
      if (!lastCert) return;
      shell.postMessage(JSON.stringify({ t: 'trustCert', origin: lastCert.origin,
        fingerprint: lastCert.fingerprint }));
      hideCert();
      signIn();
    });
    if (shell) shell.addEventListener('message', onHostMessage);
    var first = !$('host').value && shell ? 'host' : (!$('user').value ? 'user' : 'password');
    $(first).focus();
  });
})();
