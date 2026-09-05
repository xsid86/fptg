unit rlottie;

{$mode objfpc}{$H+}

{ Голый биндинг к C API rlottie (Samsung/rlottie, github.com/Samsung/
  rlottie) — рендерит Lottie-анимации (векторный JSON, формат TGS у
  Telegram — тот же JSON, только gzip-сжатый снаружи, см. lottieplayer.
  pas). Сигнатуры сверены построчно с настоящим `inc/rlottie_capi.h` из
  клонированного репозитория (не угадано), и не только — DLL реально
  собрана из этих же исходников в этой сессии (MSYS2/MinGW-w64 g++ +
  CMake, `-DBUILD_SHARED_LIBS=ON`) и проверена на настоящем рендере
  (example/lottie2gif.exe на sample-анимации из репозитория дал
  корректный 100x100 GIF) — не только скомпилировался Pascal-биндинг,
  сама C-библиотека реально работает.

  `librlottie.dll` — рядом с exe, тем же приёмом, что tdjson.dll/ffmpeg
  DLL: собрана один раз в этой сессии, коммитится в git.

  Формат вывода `lottie_animation_render` — ARGB32_Premultiplied
  (rlottie.h: "Default surface format is ARGB32_Premultiplied") — то
  есть 0xAARRGGBB на пиксель, альфа УЖЕ умножена в R/G/B. На
  little-endian x86/x64 это ровно тот же порядок байт в памяти
  (B,G,R,A), что и обычный 32-битный Windows DIB, и ровно то, что
  ожидает GDI AlphaBlend с AC_SRC_ALPHA — конвертация не нужна, только
  проскормить буфер напрямую (см. DrawPremultipliedArgbBuffer,
  framehistory.pas). }

interface

uses
  ctypes;

const
  RLOTTIE_LIB = 'librlottie.dll';

type
  PLottieAnimation = pointer;

{ Конструирует анимацию из УЖЕ РАСПАКОВАННОЙ JSON-строки (TGS
  распаковывается из gzip заранее, см. lottieplayer.pas) — не из файла:
  избавляет от необходимости писать временный .json на диск.
  AResourcePath — путь для внешних ресурсов (картинок и т.п.),
  стикерам не нужен, передаётся ''. }
function lottie_animation_from_data(AData, AKey, AResourcePath: PAnsiChar): PLottieAnimation; cdecl;
  external RLOTTIE_LIB;
procedure lottie_animation_destroy(AAnimation: PLottieAnimation); cdecl; external RLOTTIE_LIB;
procedure lottie_animation_get_size(AAnimation: PLottieAnimation; out AWidth, AHeight: SizeUInt); cdecl;
  external RLOTTIE_LIB;
function lottie_animation_get_duration(AAnimation: PLottieAnimation): cdouble; cdecl; external RLOTTIE_LIB;
function lottie_animation_get_totalframe(AAnimation: PLottieAnimation): SizeUInt; cdecl; external RLOTTIE_LIB;
function lottie_animation_get_framerate(AAnimation: PLottieAnimation): cdouble; cdecl; external RLOTTIE_LIB;
{ ABuffer — ARGB32_Premultiplied, AWidth*AHeight*4 байт, ABytesPerLine =
  AWidth*4 (без выравнивания/паддинга строк). }
procedure lottie_animation_render(AAnimation: PLottieAnimation; AFrameNum: SizeUInt;
  ABuffer: PCardinal; AWidth, AHeight, ABytesPerLine: SizeUInt); cdecl; external RLOTTIE_LIB;

implementation

end.
