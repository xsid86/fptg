# Third-party notices

fptg itself is free software under the GNU General Public License version 3
or later (`LICENSE`), with an additional permission for the Microsoft WebView2
components (`LICENSE-EXCEPTION.md`). It is built with, and ships, the
components below. Each keeps its own license; the full
texts are in `docs/licenses/` (in a release archive: `licenses/`) or next to
the component itself.

fptg uses the Telegram API and is not affiliated with or endorsed by Telegram.

## Shipped with fptg-server

| Component | Used for | License | Text |
|---|---|---|---|
| [TDLib](https://github.com/tdlib/td) (`tdjson.dll`) | Telegram client library | Boost Software License 1.0 | `TDLib-BSL-1.0.txt` |
| [OpenSSL](https://www.openssl.org/) 3 (`libssl-3-x64.dll`, `libcrypto-3-x64.dll`) | TLS for TDLib and for the server | Apache License 2.0 | `OpenSSL-Apache-2.0.txt` |
| [zlib](https://zlib.net/) (`z.dll`) | compression for TDLib | zlib License | `zlib.txt` |
| Microsoft Visual C++ runtime (`vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll`) | the runtime TDLib, OpenSSL and zlib are built against | redistributable files of the [Visual C++ Redistributable](https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files) | — |

## Compiled into the programs

| Component | Where | License | Text |
|---|---|---|---|
| Free Pascal run-time library | all programs | LGPL 2 with the static linking exception | `FreePascal-RTL-modifiedLGPL.txt`, `LGPL-2.txt` |
| [Lazarus LCL](https://www.lazarus-ide.org/) | fptg-client, fptg-server-gui | LGPL 2 with the static linking exception | `Lazarus-LCL-BGRABitmap-modifiedLGPL.txt`, `LGPL-2.txt` |
| [BGRABitmap, BGRAControls](https://github.com/bgrabitmap) | fptg-client | LGPL 2 with the static linking exception | `Lazarus-LCL-BGRABitmap-modifiedLGPL.txt`, `LGPL-2.txt` |
| [Ararat Synapse](http://www.ararat.cz/synapse/) | fptg-server, fptg-server-gui | BSD 3-Clause | `Synapse-BSD-3-Clause.txt` |
| [QRCodeGenLib4Pascal](https://github.com/Xor-el/QRCodeGenLib4Pascal) | fptg-server, fptg-server-gui | MIT | `QRCodeGenLib4Pascal-MIT.txt` |

The static linking exception lets these libraries be linked into a program
under the program's own license; the libraries themselves stay under the
LGPL, and their sources are available from the projects linked above.

## Shipped with fptg-client

| Component | Used for | License | Text |
|---|---|---|---|
| Microsoft Edge WebView2 Loader (`WebView2Loader.dll`) | starting the WebView2 runtime | Microsoft WebView2 SDK license (BSD-style) | `WebView2Loader.LICENSE.txt` next to the exe |
| [lottie-web](https://github.com/airbnb/lottie-web) | animated stickers | MIT | `web/assets/vendor/lottie/LICENSE` |
| [PhotoSwipe](https://photoswipe.com/) | photo viewer | MIT | `web/assets/vendor/photoswipe/LICENSE` |
| [Prism](https://prismjs.com/) | code highlighting | MIT | `web/assets/vendor/prism/LICENSE` |
| [Noto Color Emoji](https://github.com/googlefonts/noto-emoji) | emoji font | SIL Open Font License 1.1 | `web/assets/vendor/noto-emoji/OFL.txt` |

The Microsoft Edge WebView2 Runtime itself is not shipped: it is part of
Windows 11 and is installed separately on Windows 10.
