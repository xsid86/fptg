unit rlottie;

{$mode objfpc}{$H+}

{ Raw C API binding for rlottie (github.com/Samsung/rlottie), used to
  render Lottie animations. Telegram's TGS format is the same vector
  JSON, gzip-compressed (see lottieplayer.pas). librlottie.dll ships
  next to the executable.

  lottie_animation_render outputs ARGB32_Premultiplied (0xAARRGGBB per
  pixel, alpha pre-multiplied into R/G/B). On little-endian x86/x64
  this matches the standard 32-bit Windows DIB byte order (B,G,R,A)
  and what GDI AlphaBlend expects with AC_SRC_ALPHA, so no conversion
  is needed before blitting (see DrawPremultipliedArgbBuffer in
  framehistory.pas). }

interface

uses
  ctypes;

const
  RLOTTIE_LIB = 'librlottie.dll';

type
  PLottieAnimation = pointer;

{ Builds an animation from an already-decompressed JSON string (TGS is
  gunzipped beforehand, see lottieplayer.pas), not from a file — no
  temporary .json is written to disk. AResourcePath is a path for
  external resources (images etc.); pass '' for stickers, which don't
  need it. }
function lottie_animation_from_data(AData, AKey, AResourcePath: PAnsiChar): PLottieAnimation; cdecl;
  external RLOTTIE_LIB;
procedure lottie_animation_destroy(AAnimation: PLottieAnimation); cdecl; external RLOTTIE_LIB;
procedure lottie_animation_get_size(AAnimation: PLottieAnimation; out AWidth, AHeight: SizeUInt); cdecl;
  external RLOTTIE_LIB;
function lottie_animation_get_duration(AAnimation: PLottieAnimation): cdouble; cdecl; external RLOTTIE_LIB;
function lottie_animation_get_totalframe(AAnimation: PLottieAnimation): SizeUInt; cdecl; external RLOTTIE_LIB;
function lottie_animation_get_framerate(AAnimation: PLottieAnimation): cdouble; cdecl; external RLOTTIE_LIB;
{ ABuffer must be ARGB32_Premultiplied, AWidth*AHeight*4 bytes;
  ABytesPerLine is AWidth*4 (no row padding/alignment). }
procedure lottie_animation_render(AAnimation: PLottieAnimation; AFrameNum: SizeUInt;
  ABuffer: PCardinal; AWidth, AHeight, ABytesPerLine: SizeUInt); cdecl; external RLOTTIE_LIB;

implementation

end.
