unit emojiassets;

{ Colorful Unicode emoji rendering, offline: a single packed atlas file
  (emoji_atlas.dat, next to the exe) holds one PNG per emoji sequence.

  Source, by direct request (the user didn't like Twemoji's flatter
  style, which this atlas used before): Google's Noto Color Emoji
  (github.com/googlefonts/noto-emoji), png/72 — Apache 2.0 (the repo's
  README and the sibling svg/LICENSE both say so; the top-level LICENSE
  file text is the SIL Open Font License instead, but that one governs
  "This Font Software", i.e. the compiled fonts/ TTFs specifically, not
  the raw art under png/svg — checked directly, not assumed). Country
  flags are a SEPARATE source within the same repo, third_party/
  region-flags/png (public domain/copyright-exempt, per its own
  LICENSE) — noto-emoji's png/* doesn't ship pre-composed two-letter
  flag images at all, only single regional-indicator-letter glyphs, so
  each flag PNG (a flat 1200x600ish rectangle, not a glyph) is
  composited onto its own square transparent canvas and keyed by the
  pair of REGIONAL INDICATOR SYMBOL codepoints for its ISO code (e.g.
  "DE" -> U+1F1E9 U+1F1EA) — a flatter, non-waved rendering than Noto's
  own actual (waved+shadowed) flag glyphs, an accepted simplification,
  not a claim of pixel-fidelity. Packed via a one-off Python script
  (dev-time tool, not committed — same as the original Twemoji packer
  never was, see docs/journal/).

  The packer deliberately EXCLUDES a bare, single-codepoint entry for
  any codepoint in Unicode's own Emoji_Component set (emoji-data.txt,
  fetched and checked directly, not guessed) — keycap base characters
  (0-9, #, *), ZWJ, the combining keycap (U+20E3), VS16, the 26
  regional-indicator letters, skin-tone/hair-color modifiers, and tag
  characters. These exist ONLY to build larger sequences and are never
  valid standalone emoji on their own — but Noto's png/72 ships a bare
  PNG for several of them anyway (Twemoji, the previous source, never
  did), and a real, reported bug came directly from that: EmojiMatchAt
  happily matched a lone "2" or "0" in ordinary message text (window
  sizes, opacity values, plain numbers) and rendered it as an oversized
  colorful glyph instead of leaving it as plain text. Excluding the
  bare digit also means a real FULLY-qualified keycap sequence in
  message text (digit + VS16 + combining-keycap, e.g. an actual
  "0️⃣") could no longer match at all — Noto's own filenames only cover
  the MINIMALLY-qualified 2-codepoint form (digit + combining-keycap,
  no VS16) — so the packer additionally SYNTHESIZES the 3-codepoint
  fully-qualified key for each of the 12 keycap bases, reusing the same
  PNG bytes as the 2-codepoint version it's built from. Any other
  MULTI-codepoint sequence that happens to include a component
  codepoint (a real flag, a skin-toned "👍🏽", a ZWJ family) is
  unaffected either way — only bare single-codepoint entries were ever
  the problem.

  The atlas format: 'EMJ1', uint32 count, then per entry: uint8
  codepoint count, that many uint32 codepoints (the emoji sequence),
  uint32 PNG length, PNG bytes — unchanged from the Twemoji-sourced
  atlas, so nothing else in this file needed to change for the swap.

  EmojiMatchAt finds the longest emoji sequence starting at a given byte
  position in a UTF-8 string — driven entirely by the atlas' own key
  set, not a hand-typed table of Unicode emoji ranges: EmojiIsStarter is
  built from the first codepoint of every loaded sequence, so it can't
  drift out of sync with what's actually in the atlas. }

{$mode objfpc}{$H+}

interface

{ Windows first — later units in this list resolve identifiers like
  TRect ahead of it, so Windows.TRect/Windows.Rect never shadow
  Types'/Graphics' (same convention as framehistory.pas). The raw win32
  clip-region calls in DrawEmojiLine are still qualified explicitly
  (Windows.xxx) regardless, in case of a name clash with LCLIntf. }
uses
  Windows, Classes, SysUtils, Types, Graphics, BGRABitmap, BGRABitmapTypes,
  customemoji;

const
  EMOJI_MAX_CODEPOINTS = 12;  { longest real sequence: 10 in Twemoji, 9 in Noto Color Emoji }

type
  { A custom (Premium) emoji entity's span within some plain-text
    string, model-agnostic (no dependency on tdmessages.TMsgEntity or
    tdchats.TChatRow — both framehistory.pas/msglayout.pas, via its own
    TMsgEntity array, and framechats.pas, via TChatRow.LastGlyphs, build
    one of these arrays their own way and pass it in here). }
  TCustomGlyphSpan = record
    ByteStart, ByteLen: integer;
    CustomEmojiId: Int64;
  end;
  TCustomGlyphSpanArray = array of TCustomGlyphSpan;

procedure EmojiAssetsInit;
function EmojiIsStarter(ACp: Cardinal): boolean;
function Utf8DecodeAt(const AText: utf8string; APos: integer;
  out ACp: Cardinal; out ALen: integer): boolean;
function EmojiMatchAt(const AText: utf8string; APos: integer; out ALen: integer): boolean;
function EmojiBitmapFor(const AKey: utf8string; ASize: integer): TBGRABitmap;

{ Single-line emoji-aware replacement for TCanvas.TextRect — same
  contract (clipped to ARect, drawn from (X,Y)), used by single-line
  contexts that don't go through the word-wrap engine in msglayout.pas
  (the chat list's title/preview line). ACustomGlyphs may be nil (most
  callers, e.g. the "Archive"/"All chats" pseudo-row, never have any) —
  a span in it takes priority over an atlas match at the same position,
  the same rule msglayout.WrapText applies, and for the same reason: the
  entity's ByteLen is authoritative even when its alt text isn't a known
  atlas key. }
function DrawEmojiLine(ACanvas: TCanvas; const ARect: TRect; X, Y: integer;
  const AText: utf8string; const ACustomGlyphs: TCustomGlyphSpanArray): integer;

implementation

type
  TEmojiEntry = class
    Offset, Len:   integer;     { into FBlob }
    Bitmap:        TBGRABitmap; { native 72x72, decoded lazily }
    Resampled:     TBGRABitmap; { cached at the last requested size }
    ResampledSize: integer;
    destructor Destroy; override;
  end;

destructor TEmojiEntry.Destroy;
begin
  Resampled.Free;
  Bitmap.Free;
  inherited Destroy;
end;

var
  FLoaded:   boolean = False;
  FBlob:     TBytes;
  FIndex:    TStringList;        { Sorted, CaseSensitive; Objects[i] = TEmojiEntry }
  FStarters: array of Cardinal;  { sorted, unique — first codepoint of every key }

function Utf8CharLen(AByte: byte): integer;
begin
  if AByte < $80 then begin
    Result := 1;
  end else if AByte < $C0 then begin
    Result := 1;   { stray continuation byte — advance by one to make progress }
  end else if AByte < $E0 then begin
    Result := 2;
  end else if AByte < $F0 then begin
    Result := 3;
  end else begin
    Result := 4;
  end;
end;

function Utf8DecodeAt(const AText: utf8string; APos: integer;
  out ACp: Cardinal; out ALen: integer): boolean;
var
  B0: byte;
begin
  ACp := 0;
  ALen := 0;
  if (APos < 1) or (APos > Length(AText)) then begin
    Result := False;
    Exit;
  end;
  B0 := byte(AText[APos]);
  ALen := Utf8CharLen(B0);
  if APos + ALen - 1 > Length(AText) then begin
    Result := False;
    Exit;
  end;
  case ALen of
    1: ACp := B0;
    2: ACp := ((B0 and $1F) shl 6) or (byte(AText[APos + 1]) and $3F);
    3: ACp := ((B0 and $0F) shl 12) or ((byte(AText[APos + 1]) and $3F) shl 6)
            or (byte(AText[APos + 2]) and $3F);
  else
    ACp := ((B0 and $07) shl 18) or ((byte(AText[APos + 1]) and $3F) shl 12)
         or ((byte(AText[APos + 2]) and $3F) shl 6) or (byte(AText[APos + 3]) and $3F);
  end;
  Result := True;
end;

function CodepointToUtf8(ACp: Cardinal): utf8string;
begin
  if ACp < $80 then begin
    Result := Chr(ACp);
  end else if ACp < $800 then begin
    Result := Chr($C0 or (ACp shr 6)) + Chr($80 or (ACp and $3F));
  end else if ACp < $10000 then begin
    Result := Chr($E0 or (ACp shr 12)) + Chr($80 or ((ACp shr 6) and $3F))
            + Chr($80 or (ACp and $3F));
  end else begin
    Result := Chr($F0 or (ACp shr 18)) + Chr($80 or ((ACp shr 12) and $3F))
            + Chr($80 or ((ACp shr 6) and $3F)) + Chr($80 or (ACp and $3F));
  end;
end;

function EmojiIsStarter(ACp: Cardinal): boolean;
var
  Lo, Hi, Mid: integer;
begin
  Result := False;
  Lo := 0;
  Hi := High(FStarters);
  while Lo <= Hi do begin
    Mid := (Lo + Hi) div 2;
    if FStarters[Mid] = ACp then begin
      Result := True;
      Exit;
    end else if FStarters[Mid] < ACp then begin
      Lo := Mid + 1;
    end else begin
      Hi := Mid - 1;
    end;
  end;
end;

procedure EmojiAssetsInit;
var
  Fn: string;
  FS: TFileStream;
  Count, I, J, SeqLen, PngLen, P: integer;
  Cp: Cardinal;
  Key: utf8string;
  Entry: TEmojiEntry;
  Starters: array of Cardinal;
  StCount, K: integer;
  IsNew: boolean;
begin
  if FLoaded then begin
    Exit;
  end;
  FLoaded := True;   { even on failure — don't retry on every call site }

  Fn := ExtractFilePath(ParamStr(0)) + 'emoji_atlas.dat';
  if not FileExists(Fn) then begin
    Exit;
  end;

  FS := TFileStream.Create(Fn, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(FBlob, FS.Size);
    if FS.Size > 0 then begin
      FS.ReadBuffer(FBlob[0], FS.Size);
    end;
  finally
    FS.Free;
  end;

  if (Length(FBlob) < 8) or (FBlob[0] <> Ord('E')) or (FBlob[1] <> Ord('M'))
     or (FBlob[2] <> Ord('J')) or (FBlob[3] <> Ord('1')) then begin
    SetLength(FBlob, 0);
    Exit;
  end;

  FIndex := TStringList.Create;
  FIndex.Sorted := True;
  FIndex.Duplicates := dupIgnore;
  FIndex.CaseSensitive := True;

  P := 4;
  Count := PInteger(@FBlob[P])^;
  Inc(P, 4);
  SetLength(Starters, 0);
  StCount := 0;

  for I := 0 to Count - 1 do begin
    SeqLen := FBlob[P];
    Inc(P, 1);
    Key := '';
    for J := 0 to SeqLen - 1 do begin
      Cp := PCardinal(@FBlob[P])^;
      Inc(P, 4);
      Key := Key + CodepointToUtf8(Cp);
      if J = 0 then begin
        IsNew := True;
        for K := 0 to StCount - 1 do begin
          if Starters[K] = Cp then begin
            IsNew := False;
            Break;
          end;
        end;
        if IsNew then begin
          if StCount >= Length(Starters) then begin
            SetLength(Starters, StCount + 256);
          end;
          Starters[StCount] := Cp;
          Inc(StCount);
        end;
      end;
    end;
    PngLen := PInteger(@FBlob[P])^;
    Inc(P, 4);

    Entry := TEmojiEntry.Create;
    Entry.Offset := P;
    Entry.Len := PngLen;
    Entry.Bitmap := nil;
    Entry.Resampled := nil;
    Entry.ResampledSize := 0;
    FIndex.AddObject(string(Key), Entry);

    Inc(P, PngLen);
  end;

  SetLength(Starters, StCount);
  { insertion sort — a few thousand entries once at startup, not worth a
    generic sort routine for this }
  for I := 1 to High(Starters) do begin
    Cp := Starters[I];
    J := I - 1;
    while (J >= 0) and (Starters[J] > Cp) do begin
      Starters[J + 1] := Starters[J];
      Dec(J);
    end;
    Starters[J + 1] := Cp;
  end;
  FStarters := Starters;
end;

function EmojiMatchAt(const AText: utf8string; APos: integer; out ALen: integer): boolean;
var
  Cp: Cardinal;
  CLen, TotalLen, NCp, P: integer;
  Candidate: utf8string;
begin
  Result := False;
  ALen := 0;
  if not FLoaded then begin
    EmojiAssetsInit;
  end;
  if (FIndex = nil) or (Length(AText) = 0) or (APos < 1) or (APos > Length(AText)) then begin
    Exit;
  end;
  if not Utf8DecodeAt(AText, APos, Cp, CLen) then begin
    Exit;
  end;
  if not EmojiIsStarter(Cp) then begin
    Exit;
  end;

  TotalLen := 0;
  NCp := 0;
  P := APos;
  while (NCp < EMOJI_MAX_CODEPOINTS) and Utf8DecodeAt(AText, P, Cp, CLen) do begin
    Inc(TotalLen, CLen);
    Inc(P, CLen);
    Inc(NCp);
    Candidate := Copy(AText, APos, TotalLen);
    if FIndex.IndexOf(string(Candidate)) >= 0 then begin
      Result := True;
      ALen := TotalLen;
    end;
  end;

  { The atlas doesn't carry a distinct key for every base+VS16 (U+FE0F)
    combination — only the bare base glyph for many of them (confirmed:
    e.g. "warning sign" alone is a key, "warning sign"+VS16 is not).
    EmojiBitmapFor already has its own fallback that strips a trailing
    VS16 off the LOOKUP key when the exact key misses — but that's only
    reached if this function first agrees the VS16 bytes belong to the
    SAME glyph run. Without this, the match above stops at the base
    glyph, and the VS16 bytes are left behind as their own "word" for
    the ordinary text path — which renders as an empty/tofu box in most
    fonts (VS16 has no visible glyph of its own; a real, reported bug,
    not hypothetical). So: whatever the match above settled on, if the
    very next codepoint is VS16, swallow it into the same run too,
    regardless of whether the extended candidate is itself a known key —
    it renders the same glyph either way (EmojiBitmapFor's own fallback
    already handles that half), this only fixes how many BYTES get
    consumed for it. }
  if Result and Utf8DecodeAt(AText, APos + ALen, Cp, CLen) and (Cp = $FE0F) then begin
    Inc(ALen, CLen);
  end;
end;

function EmojiBitmapFor(const AKey: utf8string; ASize: integer): TBGRABitmap;
var
  Idx: integer;
  Entry: TEmojiEntry;
  MS: TMemoryStream;
  Key: utf8string;
begin
  Result := nil;
  if not FLoaded then begin
    EmojiAssetsInit;
  end;
  if (FIndex = nil) or (ASize <= 0) then begin
    Exit;
  end;
  Key := AKey;
  Idx := FIndex.IndexOf(string(Key));
  { A #$XX#$XX... hex-char-literal for bytes >= $80, compared against a
    utf8string, is NOT the raw byte sequence it looks like — confirmed
    by an isolated test (not assumed): FPC treats each #$XX as a
    LATIN-1 CODEPOINT and transcodes it to UTF-8 when the result's
    codepage is CP_UTF8, so a literal like #$EF#$B8#$8F silently becomes
    a 6-byte double-encoded string instead of the intended 3 raw bytes
    — which is exactly why comparing Copy(Key,...) against such a
    literal here NEVER matched (this was the actual first version of
    this fallback; found and replaced before ever shipping working).
    Checking the trailing bytes one at a time via Ord() sidesteps the
    whole codepage question — Ord() reads the byte that's really there,
    no literal-driven transcoding involved. }
  if (Idx < 0) and (Length(Key) >= 3)
     and (Ord(Key[Length(Key) - 2]) = $EF)
     and (Ord(Key[Length(Key) - 1]) = $B8)
     and (Ord(Key[Length(Key)])     = $8F) then begin
    { U+FE0F (VARIATION SELECTOR-16, "prefer the emoji-style
      presentation") is very common as a trailing codepoint on
      symbol-class glyphs (arrows, bullets, ...) — real message text
      (and, more importantly here, a custom-emoji entity's own alt
      text) almost always includes it, but the atlas' own asset naming
      never includes it at all: Twemoji (the original source) dropped
      it only for characters whose DEFAULT presentation is already
      emoji-style; Noto Color Emoji (the current source, see this
      unit's header comment) drops it UNCONDITIONALLY, confirmed
      directly against its png/72 filenames (zero "_fe0f" occurrences
      anywhere in ~3700 files) — the fallback below covers both cases
      the same way, without needing to know which source is active.
      Without it, EVERY VS16-suffixed glyph would silently fail the
      exact-key lookup here and render as nothing at all.
      WrapText/EmojiMatchAt (msglayout.pas)
      already have an equivalent effect for PLAIN text, for a different
      reason: their longest-match search naturally lands on the
      3-byte-shorter match when the full sequence isn't in the index —
      this call site is the one place that does an exact lookup instead
      (the caller already knows precisely which bytes it wants), so it
      needs its own explicit retry. }
    Key := Copy(Key, 1, Length(Key) - 3);
    Idx := FIndex.IndexOf(string(Key));
  end;
  if Idx < 0 then begin
    Exit;
  end;
  Entry := TEmojiEntry(FIndex.Objects[Idx]);

  if Entry.Bitmap = nil then begin
    MS := TMemoryStream.Create;
    try
      MS.WriteBuffer(FBlob[Entry.Offset], Entry.Len);
      MS.Position := 0;
      try
        Entry.Bitmap := TBGRABitmap.Create(MS);
      except
        Entry.Bitmap := nil;
      end;
    finally
      MS.Free;
    end;
    if Entry.Bitmap = nil then begin
      Exit;
    end;
  end;

  if (Entry.Resampled = nil) or (Entry.ResampledSize <> ASize) then begin
    FreeAndNil(Entry.Resampled);
    Entry.Bitmap.ResampleFilter := rfBestQuality;
    Entry.Resampled := Entry.Bitmap.Resample(ASize, ASize, rmFineResample);
    Entry.ResampledSize := ASize;
  end;
  Result := Entry.Resampled;
end;

function DrawEmojiLine(ACanvas: TCanvas; const ARect: TRect; X, Y: integer;
  const AText: utf8string; const ACustomGlyphs: TCustomGlyphSpanArray): integer;
var
  N, I, SegStart, SegLen, EmLen, LineH: integer;
  CustomId: Int64;
  Bmp: TBGRABitmap;
  Seg: utf8string;
  SavedClip: HRGN;
  HadClip: integer;

  { Same priority rule as msglayout.WrapText's SpecialGlyphAt: a custom
    entity wins (its ByteLen is authoritative even off-atlas), a plain
    Unicode emoji match otherwise. }
  function GlyphAt(APos: integer; out ALen: integer; out AId: Int64): boolean;
  var
    J: integer;
  begin
    AId := 0;
    for J := 0 to High(ACustomGlyphs) do begin
      if (APos >= ACustomGlyphs[J].ByteStart)
         and (APos < ACustomGlyphs[J].ByteStart + ACustomGlyphs[J].ByteLen) then begin
        ALen := ACustomGlyphs[J].ByteStart + ACustomGlyphs[J].ByteLen - APos;
        AId := ACustomGlyphs[J].CustomEmojiId;
        Result := True;
        Exit;
      end;
    end;
    Result := EmojiMatchAt(AText, APos, ALen);
  end;

begin
  N := Length(AText);
  LineH := ACanvas.TextHeight('Щ');

  { Same clipping contract as TextRect (which this replaces): a GDI clip
    region, not a per-run width check — a run straddling the boundary is
    cut off mid-glyph exactly like plain text would be, not skipped
    whole. }
  SavedClip := Windows.CreateRectRgn(0, 0, 1, 1);
  HadClip := Windows.GetClipRgn(ACanvas.Handle, SavedClip);
  Windows.IntersectClipRect(ACanvas.Handle, ARect.Left, ARect.Top, ARect.Right, ARect.Bottom);
  try
    I := 1;
    while I <= N do begin
      if GlyphAt(I, EmLen, CustomId) then begin
        Bmp := nil;
        if CustomId <> 0 then begin
          { CustomEmojiStaticBitmapFor, not CustomEmojiBitmapFor — this
            is the chat list's single-line renderer, which by direct
            request never animates custom emoji (see that function's
            own comment for why "just stop re-invalidating" alone isn't
            enough: the underlying bitmap is shared with the open chat
            history, which DOES keep animating it in place). }
          Bmp := CustomEmojiStaticBitmapFor(CustomId, LineH);
        end;
        if Bmp = nil then begin
          Bmp := EmojiBitmapFor(Copy(AText, I, EmLen), LineH);
        end;
        if Bmp <> nil then begin
          Bmp.Draw(ACanvas, X, Y, False);
        end;
        Inc(X, LineH);
        Inc(I, EmLen);
        Continue;
      end;

      SegStart := I;
      repeat
        Inc(I);
      until (I > N) or GlyphAt(I, EmLen, CustomId);
      SegLen := I - SegStart;
      Seg := Copy(AText, SegStart, SegLen);
      ACanvas.TextOut(X, Y, string(Seg));
      Inc(X, ACanvas.TextWidth(string(Seg)));
    end;
  finally
    if HadClip = 1 then begin
      Windows.SelectClipRgn(ACanvas.Handle, SavedClip);
    end else begin
      Windows.SelectClipRgn(ACanvas.Handle, 0);
    end;
    Windows.DeleteObject(SavedClip);
  end;
  Result := X;
end;

procedure FreeIndex;
var
  I: integer;
begin
  if FIndex <> nil then begin
    for I := 0 to FIndex.Count - 1 do begin
      FIndex.Objects[I].Free;
    end;
    FIndex.Free;
  end;
end;

finalization
  FreeIndex;

end.
