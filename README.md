# fptg

A Telegram client written in Free Pascal and Lazarus, built on
[TDLib](https://github.com/tdlib/td).

fptg is split into two programs:

- **fptg-server** keeps your Telegram account. It runs TDLib and serves the
  interface over HTTPS and WebSocket. You can run it on your own PC or on a
  VPS, so your Telegram session lives on a machine you control.
- **fptg-client** is a desktop window (Microsoft Edge WebView2) that
  connects to the server by address and port. It adds a tray icon, desktop
  notification cards, a call pop-up and mini app windows. Any modern
  browser works as a client too.

The interface follows Telegram Desktop: chats, folders, archive, search,
media, stickers and custom emoji, voice and video messages, calls and video
chats, bots and mini apps, stories, scheduled messages, Telegram Business
and Premium settings.

fptg uses the Telegram API and is not affiliated with or endorsed by
Telegram.

## How it works

```
fptg-client (WebView2)  ─┐
                         ├─ HTTPS + WebSocket ─>  fptg-server  ─>  TDLib  ─>  Telegram
any browser             ─┘     (TLS, JWT)
```

- The server has one user: a single login and password protect it.
- TLS is always on. Without your own certificate the server makes a
  self-signed one and prints its fingerprint. The client asks you to check
  that fingerprint once and then remembers it.
- After sign-in the page works with short-lived JWT tokens. The window keeps
  only the server address, a refresh token and the certificate fingerprint,
  encrypted with Windows DPAPI.

## Requirements

**To run:**

- 64-bit Windows 10 or 11, or Windows Server 2016 or newer (server).
- The Microsoft Edge WebView2 Runtime for fptg-client. Windows 11 has it
  built in. On Windows 10 the client offers to download it, or get it from
  <https://developer.microsoft.com/microsoft-edge/webview2/>.
- A Telegram `api_id` and `api_hash` from <https://my.telegram.org>,
  unless your build has keys built in (see [API keys](#api-keys)).

**To build:**

- [Lazarus](https://www.lazarus-ide.org/) 4.x with Free Pascal 3.2.2,
  64-bit (x86_64-win64).
- These Lazarus packages, all available in the Online Package Manager
  (Package → Online Package Manager):
  - `laz_synapse` (Ararat Synapse 40.1): the server's HTTPS. The server
    projects also compile units from Synapse's `ssl_openssl3` folder,
    which the package itself does not include.
  - `QRCodeGenLib4PascalPackage`: QR codes for signing in to Telegram.
  - `BGRABitmapPack` and `bgracontrols`: the client window.
- Python 3, only if you want to make release archives.

The runtime DLLs are already in the repository:

- `fptg-server/` has `tdjson.dll` (TDLib 1.8.67) with `libssl-3-x64.dll`,
  `libcrypto-3-x64.dll` and `z.dll`;
- `fptg-client/` has `WebView2Loader.dll`.

## Building

Each program has its own Lazarus project:

| Project | Result |
|---|---|
| `fptg-server/fptg-server.lpi` | `fptg-server.exe`, console server, no LCL |
| `fptg-server/fptg-server-gui.lpi` | `fptg-server-gui.exe`, the same server with a window and a tray icon |
| `fptg-client/fptg-client.lpi` | `fptg-client.exe`, the client window |

Open a project in Lazarus and press Build, or build from the command line:

```bat
lazbuild -B fptg-server\fptg-server.lpi
lazbuild -B fptg-server\fptg-server-gui.lpi
lazbuild -B --build-mode=Release fptg-client\fptg-client.lpi
```

The `.exe` files appear next to their project.

The page (`fptg-client/web/`) is plain HTML, JavaScript modules and CSS,
with no build step at run time. The styles are written in SCSS, and the
compiled `assets/scss/style.css` is committed. After you change a `.scss`
file, compile it again with [Dart Sass](https://sass-lang.com/):

```bat
sass fptg-client\web\assets\scss\style.scss fptg-client\web\assets\scss\style.css
```

### API keys

Telegram identifies every application by an `api_id` and `api_hash`. The
public build has no keys built in (`fptg-server/shared/keys/apikeys.inc`
holds empty values), and the interface asks for yours the first time you
sign in.

To build with your own keys, put a copy of that file with real values in
`fptg-server-premium/apikeys.inc` at the repository root. Git ignores that
folder, and the server projects look there before `shared/keys/`. Never
commit real keys.

### Release archives

```bat
python tools\build_release.py 1.0.0
```

This rebuilds all three programs and writes to `dist/`:

- `fptg-server-<version>-win64.zip`;
- `fptg-client-<version>-win64.zip`;
- `SHA256SUMS.txt`.

Close the server and client windows first: a running program's `.exe`
cannot be overwritten. `tools/sandbox.wsb` opens a clean Windows Sandbox
with `dist/` mapped inside, which is useful for testing a release.

## Installation

There is no installer: unpack the archives into any folders.

**Server** (`fptg-server-<version>-win64.zip`):

```
fptg-server.exe        console server, for a VPS or a service
fptg-server-gui.exe    the same server with a window and a tray icon
tdjson.dll + libssl-3-x64.dll, libcrypto-3-x64.dll, z.dll
web\                   the interface the server serves to browsers
```

**Client** (`fptg-client-<version>-win64.zip`): `fptg-client.exe`,
`WebView2Loader.dll` and `web\`.

Programs and data are kept apart. The data lives in your Windows profile,
never next to the programs:

| Folder | Contents |
|---|---|
| `%LOCALAPPDATA%\fptg\server\` | TDLib database, settings, uploads |
| `%LOCALAPPDATA%\fptg\client\` | the window's connection settings |
| `%LOCALAPPDATA%\fptg\webview2\` | the WebView2 profile |

## First run

### With the server window

1. Start `fptg-server-gui.exe`.
2. Choose User → Change… and set a login and a password.
3. Pick the address and port, then press Start. The window shows the
   certificate fingerprint.
4. Closing the window hides it to the tray. To stop the server, choose
   Exit in the tray menu.

### With the console server

```bat
fptg-server.exe --set-user=alice
fptg-server.exe
```

The first command asks for a password and stores the user. The second
starts the server, which prints its address, port and certificate
fingerprint. Ctrl+C shuts it down cleanly.

| Option | Meaning |
|---|---|
| `--server-port=N` | the port (default 7654) |
| `--bind=ADDRESS` | where to listen: `127.0.0.1` (default) is this computer only, `0.0.0.0` is all networks |
| `--web-dir=PATH` | the page folder for browsers (default `web` next to the exe, or `../fptg-client/web` in the source tree) |
| `--cert=FILE --key=FILE` | your own TLS certificate and key (PEM) instead of the self-signed one |
| `--set-user=LOGIN` | set the login and password, then exit |
| `--sign-out` | end all sessions (every window and browser signs in again), then exit |
| `--tdlib-log` | keep the raw TDLib log for this run; off by default because it holds all messages in plain text |

Only one server runs per computer. A second start with `--set-user` or
`--sign-out` passes the command to the running server and exits.

To reach a server from other machines, bind it to `0.0.0.0` and allow the
port in Windows Firewall:

```bat
netsh advfirewall firewall add rule name="fptg" dir=in action=allow protocol=TCP localport=7654
```

### Connecting

1. Start `fptg-client.exe`.
2. Enter the server's address and port.
3. Compare the fingerprint the client shows with the one the server
   printed, and trust it.
4. Sign in with the server's login and password.
5. On the first sign-in, connect your Telegram account: by QR code from the
   phone, or by phone number and code.

In a browser, open `https://<address>:<port>/` and sign in the same way.

## Repository layout

```
fptg-server/         the server: TDLib core (td*.pas), the page bridge (webapi.pas),
                     HTTPS/WebSocket server, sign-in, settings
  panel/             the server window (fptg-server-gui)
  shared/            units shared with the client
fptg-client/         the client window: WebView2 host, tray, notifications, call pop-up
  web/               the interface itself (HTML, JS modules, SCSS)
tools/               release script and sandbox configuration
docs/licenses/       full texts of third-party licenses
```

## License

fptg is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License, version 3 or later (`LICENSE`).
`LICENSE-EXCEPTION.md` adds a permission for the Microsoft WebView2
components. Third-party components and their licenses are listed in
`THIRD-PARTY-NOTICES.md`.
